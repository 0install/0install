(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
module U = Support.Utils

(** There are several different versions of the PackageKit API. This module provides a consistent interface to them. *)
module Generic_client : sig
  module Transaction : sig
    type t

    val monitor : t -> switch:Lwt_switch.t -> int32 React.signal Lwt.t
    (** [monitor t ~switch] is a signal giving the percentage complete for the transaction. *)

    val cancel : t -> unit Lwt.t
    (** [cancel t] asks PackageKit to cancel the transaction. *)

    val install_packages : t -> string list -> unit Lwt.t
    (** [install_packages t ids] installs the packages with the given package IDs. *)
  end

  type t
  val connect : Support.Locale.lang_spec -> [`Ok of t | `Unavailable of string] Lwt.t
  val summaries : t -> package_names:string list -> (package_id:string -> summary:string -> unit) -> unit Lwt.t
  val sizes : t -> package_ids:string list -> (package_id:string -> size:int64 -> unit) -> unit Lwt.t
  val run_transaction : t -> (Lwt_switch.t -> Transaction.t -> unit Lwt.t) -> unit Lwt.t
end = struct
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
      U.with_switch (fun switch ->
        let error = ref None in
        let finished, waker = Lwt.wait () in

        let finish (status, _runtime) =
          log_info "packagekit: transaction finished (%s)" status;
          let err = !error in
          error := None;
          match err with
          | None when status = "success" -> Lwt.wakeup waker ()
          | None -> Lwt.wakeup_exn waker (Safe_exception ("PackageKit transaction failed: " ^ status, ref []))
          | Some (code, msg) ->
              let ex = Safe_exception (code ^ ": " ^ msg, ref []) in
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

  let connect lang_spec =
    Dbus.system () >>= function
    | `Error reason ->
        log_debug "Can't connect to system D-BUS; PackageKit support disabled (%s)" reason;
        Lwt.return (`Unavailable (Printf.sprintf "PackageKit not available: %s" reason))
    | `Ok bus ->
        let raw = Dbus.OBus_proxy.make
          ~peer:(Dbus.OBus_peer.make ~connection:bus ~name:"org.freedesktop.PackageKit")
          ~path:["org"; "freedesktop"; "PackageKit"] in
        try_lwt
          let version = IPackageKit.([p_VersionMajor; p_VersionMinor; p_VersionMicro]) |>  Lwt_list.map_p (fun prop ->
            Dbus.OBus_property.get (Dbus.OBus_property.make prop raw)
          ) in
          Lwt_timeout.create 5 (fun () -> Lwt.cancel version) |> Lwt_timeout.start;
          version >>= fun version ->
          let version = version |> List.map Int32.to_int in
          log_info "Found PackageKit D-BUS service, version %s" (String.concat "." (List.map string_of_int version));

          let version =
            if version > [6] then (
              log_info "PackageKit version number suspiciously high; assuming buggy Ubuntu aptdaemon and adding 0. to start";
              0 :: version
            ) else version in
          Lwt.return (`Ok {raw; version; lang_spec})
        with
        | Lwt.Canceled ->
            log_warning "Timed-out waiting for PackageKit to report its version number!";
            Lwt.return (`Unavailable "Timed-out waiting for PackageKit to report its version number!")
        | Dbus.OBus_bus.Service_unknown msg | Dbus.OBus_error.Unknown_object msg ->
            log_info "PackageKit not available: %s" msg;
            Lwt.return (`Unavailable (Printf.sprintf "PackageKit not available: %s" msg))

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
end

type package_info = {
  version : Version.t;
  machine : Arch.machine option;
  installed : bool;
  retrieval_method : Impl.distro_retrieval_method;
}

type packagekit_id = string
type size = Int64.t

type query_result = {
  results : package_info list;
  problems : string list;
}

class type ui =
  object
    method monitor : Downloader.download -> unit
    method confirm : string -> [`ok | `cancel] Lwt.t
    method impl_added_to_store : unit
  end

class type packagekit =
  object
    method status : [`Ok | `Unavailable of string] Lwt.t
    method get_impls : string -> query_result
    method check_for_candidates : 'a. ui:(#ui as 'a) -> hint:string -> string list -> unit Lwt.t
    method install_packages : 'a. (#ui as 'a) -> (Impl.distro_implementation * Impl.distro_retrieval_method) list -> [ `ok | `cancel ] Lwt.t
  end

(** PackageKit refuses to process more than 100 requests per transaction, so never ask for more than this in a single request. *)
let max_batch_size = 100

(** Wait for a task to complete, but ignore the actual return value. *)
let lwt_wait_for task =
  task >|= ignore

let add_package details ~package_id ~summary =
  log_info "packagekit: resolved %s: %s" package_id summary;
  match Str.bounded_split_delim U.re_semicolon package_id 4 with
  | [package_name; version; machine; repo] ->
      Hashtbl.add details package_name begin
        match Version.try_cleanup_distro_version version with
        | None ->
            `Error (Printf.sprintf "Failed to parse version string '%s' for '%s'" version package_name)
        | Some version ->
            let machine = Support.System.canonical_machine machine in
            `Ok {
              version;
              machine = Arch.parse_machine machine;
              installed = (repo = "installed");
              retrieval_method = { Impl.
                distro_size = None;    (* Gets filled in later *)
                distro_install_info = ("packagekit", package_id)
              }
            }
      end
  | _ ->
      log_warning "Malformed package ID returned by PackageKit: '%s'" package_id

(** Convert short names to PackageKit IDs (e.g. "gnupg" -> "gnupg;2.0.22;x86_64;arch") *)
let resolve proxy package_names =
  let details = Hashtbl.create 10 in
  lwt () =
    try_lwt
      Generic_client.summaries proxy ~package_names (add_package details)
    with Safe_exception _ as ex ->
      (* This is a bit broken. PackageKit seems to abort on the first unknown package, so we
       * lose the remaining results. Still, something is better than nothing... *)
      log_debug ~ex "Error resolving %s with PackageKit" (String.concat "," package_names);
      Lwt.return () in

  let add map name = map |> StringMap.add name (Hashtbl.find_all details name) in
  let results = package_names |> List.fold_left add StringMap.empty in
  Lwt.return results

(** Get the sizes of the candidate packages. *)
let get_sizes proxy = function
  | [] -> Lwt.return StringMap.empty      (* PackageKit can't handle empty queries *)
  | package_ids ->
      let details = ref StringMap.empty in
      let add ~package_id ~size =
        details := !details |> StringMap.add package_id size in
      Generic_client.sizes proxy ~package_ids add >|= fun () ->
      !details

let get_packagekit_id = function
  | {Impl.distro_install_info = ("packagekit", id); _} -> id
  | _ -> assert false

let rec get_total acc = function
  | [] -> Some acc
  | (_impl, {Impl.distro_size = Some size; _}) :: xs -> get_total (Int64.add acc size) xs
  | (_impl, {Impl.distro_size = None; _}) :: _ -> None

(** Install distribution packages. *)
let install (ui:#ui) proxy items =
  let packagekit_ids = items |> List.map (fun (_impl, rm) -> get_packagekit_id rm) in
  let total_size = get_total Int64.zero items in
  let finished, set_finished = Lwt_react.S.create false in
  try_lwt
    let cancelled = ref false in
    Generic_client.run_transaction proxy (fun switch proxy ->
      Generic_client.Transaction.monitor ~switch proxy >>= fun percentage ->
      let progress = Lwt_react.S.l2 (fun perc finished ->
        match total_size with
        | Some size when size <> Int64.zero ->
            let frac = min 1.0 @@ (Int32.to_float perc) /. 100. in
            (Int64.of_float (frac *. (Int64.to_float size)), total_size, finished)
        | _ -> (Int64.of_int32 perc, None, finished)
      ) percentage finished in
      let cancel () =
        if not !cancelled then (
          cancelled := true;
          log_info "Cancelling PackageKit installation";
          try_lwt
            Generic_client.Transaction.cancel proxy
          with ex ->
            log_warning ~ex "packagekit: cancel failed";
            Lwt.return ()
        ) else Lwt.return () in

      (* Notify the start of all downloads (we share the overall progress between them currently). *)
      items |> List.iter (fun (impl, _rm) ->
        let main_feed =
          match Impl.get_attr_ex Constants.FeedAttr.from_feed impl |> Feed_url.parse with
          | `distribution_feed main_feed -> main_feed
          | (`local_feed x | `remote_feed x) as main_feed -> log_warning "Not a distribution feed: %s" x; main_feed in
        ui#monitor Downloader.({cancel; url = "(packagekit)"; progress; hint = Some (Feed_url.format_url main_feed)})
      );

      Generic_client.Transaction.install_packages proxy packagekit_ids
    ) >>= fun () ->
    (* Mark each package as now installed (possibly we should do this individually in a signal callback instead). *)
    items |> List.iter (fun (impl, _rm) ->
      let `package_impl info = impl.Impl.impl_type in
      info.Impl.package_state <- `installed
    );
    ui#impl_added_to_store;
    Lwt.return (if !cancelled then `cancel else `ok)
  finally
    set_finished true;
    Lwt.return ()

let make lang_spec =
  let proxy = lazy (Generic_client.connect lang_spec) in

  (* Send a single PackageKit transaction for these packages. *)
  let fetch_batch proxy queries =
    log_info "packagekit: requesting details for %s" (String.concat ", " (List.map fst queries));

    try_lwt
      (* Convert short names to PackageKit IDs *)
      resolve proxy (List.map fst queries) >>= fun resolutions ->

      let package_ids = StringMap.fold (fun _ infos acc ->
        infos |> List.fold_left (fun acc info ->
          match info with
          | `Ok info -> get_packagekit_id info.retrieval_method :: acc
          | `Error _ -> acc
        ) acc
      ) resolutions [] in

      if List.length package_ids > 0 then
        log_debug "packagekit: requesting package sizes for %s" (String.concat ", " (List.map String.escaped package_ids))
      else
        log_debug "packagekit: no packages found";

      (* Collect package sizes *)
      lwt sizes =
        try_lwt
          get_sizes proxy package_ids
        with ex ->
          log_warning ~ex "packagekit: GetDetails failed";
          Lwt.return StringMap.empty in

      log_info "packagekit: fetch_batch done";
      (* Notify that each query is done *)
      queries |> List.iter (fun (name, resolver) ->
        let impls = StringMap.find name resolutions |> default [] in
        let problems = ref [] in

        if impls = [] then
          problems := Printf.sprintf "'%s' details not in PackageKit response" name :: !problems;

        (* Update [resolutions] with the size information *)
        let add_size = function
          | `Error msg -> problems := Printf.sprintf "%s: %s" name msg :: !problems; None
          | `Ok impl ->
          let rm = impl.retrieval_method in
          let packagekit_id = get_packagekit_id rm in
          match StringMap.find packagekit_id sizes with
          | Some _ as size -> Some {impl with retrieval_method = {rm with Impl.distro_size = size}}
          | None ->
              log_info "No size returned for '%s'" packagekit_id;
              Some impl in

        let results = U.filter_map add_size impls in
        Lwt.wakeup resolver {
          results;
          problems = !problems;
        }
      );

      Lwt.return ()
    with ex ->
      queries |> List.iter (fun (_, resolver) ->
        Lwt.wakeup_exn resolver ex
      );
      Lwt.return () in

  object (_ : packagekit)
    val candidates : (string, query_result Lwt.t) Hashtbl.t = Hashtbl.create 10

    (** Names of packages we're about to issue a query for and their resolvers/wakers. *)
    val mutable next_batch = []

    method status =
      Lazy.force proxy >|= function
      | `Ok _proxy -> `Ok
      | `Unavailable _ as un -> un

    (** Add any cached candidates.
        The candidates are those discovered by a previous call to [check_for_candidates].
        @param package_name the distribution's name for the package *)
    method get_impls package_name =
      let task = try Hashtbl.find candidates package_name with Not_found -> Lwt.return { results = []; problems = [] } in

      match Lwt.state task with
      | Lwt.Sleep -> { results = []; problems = [] }                 (* Fetch still in progress *)
      | Lwt.Fail ex -> { results = []; problems = [Printexc.to_string ex] }     (* Fetch failed *)
      | Lwt.Return packages -> packages

    (** Request information about this package from PackageKit. *)
    method check_for_candidates ~ui ~hint package_names =
      Lazy.force proxy >>= function
      | `Unavailable _ -> Lwt.return ()
      | `Ok proxy ->
          let progress, set_progress = Lwt_react.S.create (Int64.zero, None, false) in
          try_lwt
            let waiting_for = ref [] in

            let cancel () = !waiting_for |> List.iter Lwt.cancel; Lwt.return () in
            ui#monitor Downloader.({cancel; url = "(packagekit query)"; progress; hint = Some hint});

            log_info "Querying PackageKit for '%s'" (String.concat ", " package_names);

            let do_batch () =
              let next = next_batch in
              next_batch <- [];
              if next <> [] then
                U.async (fun () -> fetch_batch proxy next) in

            (* Create a promise for each package and add it to [candidates].
             * Pass the resolvers to fetch_batch (in groups of up to [max_batch_size]).
             * If we're already fetching, just take the existing promise.
             *)
            package_names |> List.iter (fun name ->
              let in_progress =
                try
                  let existing_task = Hashtbl.find candidates name in
                  match Lwt.state existing_task with
                  | Lwt.Return _ | Lwt.Fail _ -> false
                  | Lwt.Sleep ->
                      waiting_for := lwt_wait_for existing_task :: !waiting_for;
                      true
                with Not_found -> false in

              if not in_progress then (
                let task, waker = Lwt.task () in
                Hashtbl.replace candidates name task;
                waiting_for := lwt_wait_for task :: !waiting_for;
                next_batch <- (name, waker) :: next_batch;

                if List.length next_batch = max_batch_size then do_batch ()
              )
            );

            (* Yield briefly, so that other packages can be added to the final batch. *)
            lwt () = Lwt_main.yield () in
            (* (note: next_batch might also have become empty, if someone else added our items to their batch) *)
            do_batch ();

            Lwt.join !waiting_for
          with
          | Lwt.Canceled ->
              Lwt.return ()
          | ex ->
              log_warning ~ex "Error querying PackageKit";
              Lwt.return ()
          finally
            set_progress (Int64.zero, None, true); (* Stop progress indicator *)
            Lwt.return ()

    method install_packages (ui:#ui) items : [ `ok | `cancel ] Lwt.t =
      let packagekit_ids = items |> List.map (fun (_impl, rm) -> get_packagekit_id rm) in
      ui#confirm (
        "The following components need to be installed using native packages. \
         These come from your distribution, and should therefore be trustworthy, but they also \
         run with extra privileges. In particular, installing them may run extra services on your \
         computer or affect other users. You may be asked to enter a password to confirm. The \
         packages are:\n\n- " ^ (String.concat "\n- " packagekit_ids)
      ) >>= function
      | `cancel -> Lwt.return `cancel
      | `ok ->
          Lazy.force proxy >>= function
          | `Ok pk -> install ui pk items
          | `Unavailable _ -> failwith "BUG: PackageKit has disappeared!"
  end
