(* Copyright (C) 2016, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** There are several different versions of the PackageKit API. This module provides a consistent interface to them. *)

open Support
open Support.Common

(** [keep ~switch value] prevents [value] from being garbage collected until the switch is turned off.
 * See http://stackoverflow.com/questions/19975140/how-to-stop-ocaml-garbage-collecting-my-reactive-event-handler *)
let keep =
  let kept = Hashtbl.create 10 in
  let next = ref 0 in
  fun ~switch value ->
    let ticket = !next in
    incr next;
    Hashtbl.add kept ticket value;
    Lwt_switch.add_hook (Some switch) (fun () ->
      Hashtbl.remove kept ticket;
      Lwt.return ()
    )

type sig_handler = SigHandler : 'a Dbus.OBus_member.Signal.t * ('a -> unit) -> sig_handler

module Transaction = struct
  module ITrans = Packagekit_interfaces.Org_freedesktop_PackageKit_Transaction

  type t = {
    raw : Dbus.OBus_proxy.t;
    version : int list;
  }

  let create ~peer ~version path =
    {
      raw = Dbus.OBus_proxy.make ~peer ~path;
      version;
    }

  let set_locale t lang_spec =
    let locale = Support.Locale.format_lang lang_spec in
    if t.version >= [0; 6; 0] then
      Dbus.OBus_method.call ITrans.m_SetHints t.raw ["locale=" ^ locale]
    else
      Dbus.OBus_method.call ITrans.m_SetLocale t.raw locale

  let resolve t package_names =
    if t.version >= [0; 8; 1] then
      Dbus.OBus_method.call ITrans.m_Resolve2 t.raw (Int64.zero, package_names)
    else
      Dbus.OBus_method.call ITrans.m_Resolve t.raw ("none", package_names)

  let get_details t package_ids =
    Dbus.OBus_method.call ITrans.m_GetDetails t.raw package_ids

  let monitor t ~switch =
    Dbus.OBus_property.monitor ~switch (Dbus.OBus_property.make ITrans.p_Percentage t.raw)

  let cancel t =
    Dbus.OBus_method.call ITrans.m_Cancel t.raw ()

  let install_packages t packagekit_ids =
    if t.version >= [0;8;1] then
      Dbus.OBus_method.call ITrans.m_InstallPackages2 t.raw (Int64.zero, packagekit_ids)
    else
      Dbus.OBus_method.call ITrans.m_InstallPackages t.raw (false, packagekit_ids)

  let connect_signals t ~switch signals =
    signals |> Lwt_list.iter_p (fun (SigHandler (signal, handler)) ->
        Dbus.OBus_signal.(connect ~switch (make signal t.raw)) >|= fun event ->
        Lwt_react.E.map (handler : _ -> unit) event |> keep ~switch
      )

  let on_error t cb =
    if t.version >= [0;8;1] then (
      SigHandler (ITrans.s_ErrorCode2, fun (code, details) -> cb (Int32.to_string code, details))
    ) else SigHandler (ITrans.s_ErrorCode, cb)

  let on_finished t cb =
    if t.version >= [0;8;1] then (
      SigHandler (ITrans.s_Finished2, function
          | (1l, runtime) -> cb ("success", runtime)
          | (status, runtime) -> cb (Printf.sprintf "failed (PkExitEnum=%ld)" status, runtime)
        )
    ) else SigHandler (ITrans.s_Finished1, cb)

  let package_signal t cb =
    let cb (_, package_id, summary) = cb ~package_id ~summary in
    if t.version >= [0; 8; 1] then SigHandler (ITrans.s_Package2, cb)
    else SigHandler (ITrans.s_Package1, cb)

  let details_signal t cb =
    let update_new map =
      try
        let package_id = List.assoc "package-id" map |> Dbus.OBus_value.C.(cast_single basic_string) in
        let size = List.assoc "size" map |> Dbus.OBus_value.C.(cast_single basic_uint64) in
        cb ~package_id ~size
      with Not_found | Dbus.OBus_value.C.Signature_mismatch ->
        let items = map |> List.map (fun (k, v) ->
          Printf.sprintf "%s=%s" k (Dbus.OBus_value.V.string_of_single v)
        ) in
        log_warning "Invalid Details message from PackageKit: {%s}" (String.concat ", " items) in
    let update_old (package_id, _license, _group, _detail, _url, size) =
      log_info "packagekit: got size %s: %s" package_id (Int64.to_string size);
      cb ~package_id ~size in
    if t.version >= [0; 9; 1] then SigHandler (ITrans.s_Details3, update_new)
    else if t.version >= [0; 8; 1] then SigHandler (ITrans.s_Details2, update_old)
    else SigHandler (ITrans.s_Details1, update_old)

  let run t cb =
    Support.Utils.with_switch (fun switch ->
      let error = ref None in
      let finished, waker = Lwt.wait () in

      let finish (status, _runtime) =
        log_info "packagekit: transaction finished (%s)" status;
        let err = !error in
        error := None;
        match err with
        | None when status = "success" -> Lwt.wakeup waker ()
        | None -> Lwt.wakeup_exn waker (Safe_exn.v "PackageKit transaction failed: %s" status)
        | Some (code, msg) ->
            let ex = Safe_exn.v "%s: %s" code msg in
            Lwt.wakeup_exn waker ex in

      let error (code, details) =
        log_info "packagekit error: %s: %s" code details;
        error := Some (code, details) in

      let connect_error = on_error t error in
      let finished_signal = on_finished t finish in
      let signals = [finished_signal; connect_error] in

      (* Start operation *)
      cb ~signals ~switch t >>= fun () ->

      (* Wait for Finished signal *)
      finished
    )
end

module IPackageKit = Packagekit_interfaces.Org_freedesktop_PackageKit

type t = {
  raw : Dbus.OBus_proxy.t;
  version : int list;
  lang_spec : Support.Locale.lang_spec;
}

let get_version raw =
  let version = IPackageKit.([p_VersionMajor; p_VersionMinor; p_VersionMicro]) |>  Lwt_list.map_p (fun prop ->
    Dbus.OBus_property.get (Dbus.OBus_property.make prop raw)
  ) in
  Lwt_timeout.create 5 (fun () -> Lwt.cancel version) |> Lwt_timeout.start;
  version >|= fun version ->
  let version = List.map Int32.to_int version in
  log_info "Found PackageKit D-BUS service, version %s" (String.concat "." (List.map string_of_int version));
  if version > [6] then (
    log_info "PackageKit version number suspiciously high; assuming buggy Ubuntu aptdaemon and adding 0. to start";
    0 :: version
  ) else version

let connect lang_spec =
  Dbus.system () >>= function
  | `Error reason ->
      log_debug "Can't connect to system D-BUS; PackageKit support disabled (%s)" reason;
      Lwt.return (`Unavailable (Printf.sprintf "PackageKit not available: %s" reason))
  | `Ok bus ->
      let raw = Dbus.OBus_proxy.make
        ~peer:(Dbus.OBus_peer.make ~connection:bus ~name:"org.freedesktop.PackageKit")
        ~path:["org"; "freedesktop"; "PackageKit"] in
      Lwt.catch (fun () -> get_version raw >|= fun version -> `Ok {raw; version; lang_spec})
        (function
          | Lwt.Canceled ->
            log_warning "Timed-out waiting for PackageKit to report its version number!";
            Lwt.return (`Unavailable "Timed-out waiting for PackageKit to report its version number!")
          | Dbus.OBus_bus.Service_unknown msg | Dbus.OBus_error.Unknown_object msg ->
            log_info "PackageKit not available: %s" msg;
            Lwt.return (`Unavailable (Printf.sprintf "PackageKit not available: %s" msg))
          | ex ->
            (* obus 1.2.0 raises `E` *)
            log_info ~ex "PackageKit not available";
            Lwt.return (`Unavailable (Printf.sprintf "PackageKit not available: %s" (Printexc.to_string ex)))
        )

let create_transaction t =
  begin if t.version >= [0;8;1] then
    Dbus.OBus_method.call IPackageKit.m_CreateTransaction t.raw ()
  else
    Dbus.OBus_method.call IPackageKit.m_GetTid t.raw () >|= Dbus.OBus_path.of_string
  end >|= fun path ->
  let peer = t.raw.Dbus.OBus_proxy.peer in
  Transaction.create ~peer ~version:t.version path

let run_transaction t cb =
  create_transaction t >>= fun trans_proxy ->
  Transaction.set_locale trans_proxy t.lang_spec >>= fun () ->
  Transaction.run trans_proxy cb

let summaries t ~package_names cb =
  run_transaction t (fun ~signals ~switch trans_proxy ->
      let package_signal = Transaction.package_signal trans_proxy cb in
      Transaction.connect_signals ~switch trans_proxy (package_signal :: signals) >>= fun () ->
      Transaction.resolve trans_proxy package_names
  )

let sizes t ~package_ids cb =
  run_transaction t (fun ~signals ~switch trans_proxy ->
      let details_signal = Transaction.details_signal trans_proxy cb in
      Transaction.connect_signals ~switch trans_proxy (details_signal :: signals) >>= fun () ->
      Transaction.get_details trans_proxy package_ids
  )

let run_transaction t cb =
  run_transaction t (fun ~signals ~switch trans_proxy ->
      Transaction.connect_signals ~switch trans_proxy signals >>= fun () ->
      cb switch trans_proxy
    )
