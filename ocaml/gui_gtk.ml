(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A GTK GUI plugin *)

open Support.Common

module Ui = Zeroinstall.Ui
module Python = Zeroinstall.Python

class gui_ui (slave:Python.slave) =
  let downloads = Hashtbl.create 10 in

  let json_of_votes =
    List.map (function
      | Ui.Good, msg -> `List [`String "good"; `String msg]
      | Ui.Bad, msg -> `List [`String "bad"; `String msg]
    ) in

  let () =
    Python.register_handler "abort-download" (function
      | [`String id] ->
          begin try
            let cancel, _progress = Hashtbl.find downloads id in
            Lwt.bind (cancel ()) (fun () -> Lwt.return `Null)
          with Not_found ->
            log_info "abort-download: %s not found" id;
            Lwt.return `Null end
      | json -> raise_safe "download-archives: invalid request: %s" (Yojson.Basic.to_string (`List json))
    ) in

  object (_ : #Ui.ui_handler)
    method start_monitoring ~cancel ~url ~progress ?hint ~id =
      let size =
        match snd @@ Lwt_react.S.value progress with
        | None -> `Null
        | Some size -> `Float (Int64.to_float size) in
      let hint =
        match hint with
        | None -> `Null
        | Some hint -> `String hint in
      let details = `Assoc [
        ("url", `String url);
        ("hint", hint);
        ("size", size);
        ("tempfile", `String id);
      ] in
      let updates = progress |> Lwt_react.S.map_s (fun (sofar, total) ->
        if Hashtbl.mem downloads id then (
          let sofar = Int64.to_float sofar in
          let total =
            match total with
            | None -> `Null
            | Some total -> `Float (Int64.to_float total) in
          slave#invoke "set-progress" [`String id; `Float sofar; total] Python.expect_null
        ) else Lwt.return ()
      ) in
      Hashtbl.add downloads id (cancel, updates);     (* (store updates to prevent GC) *)
      slave#invoke "start-monitoring" [details] Python.expect_null

    method stop_monitoring id =
      Hashtbl.remove downloads id;
      slave#invoke "stop-monitoring" [`String id] Python.expect_null

    method confirm_keys feed_url infos =
      let pending_tasks = ref [] in

      let handle_pending fingerprint votes =
        let task =
          lwt votes = votes in
          slave#invoke "update-key-info" [`String fingerprint; `List (json_of_votes votes)] Python.expect_null in
        pending_tasks := task :: !pending_tasks in

      try_lwt
        let json_infos = infos |> List.map (fun (fingerprint, votes) ->
          let json_votes =
            match Lwt.state votes with
            | Lwt.Sleep -> handle_pending fingerprint votes; [`String "pending"]
            | Lwt.Fail ex -> [`List [`String "bad"; `String (Printexc.to_string ex)]]
            | Lwt.Return votes -> json_of_votes votes in
          (fingerprint, `List json_votes)
        ) in
        slave#invoke "confirm-keys" [`String (Zeroinstall.Feed_url.format_url feed_url); `Assoc json_infos] (function
          | `List confirmed_keys -> confirmed_keys |> List.map Yojson.Basic.Util.to_string
          | _ -> raise_safe "Invalid response"
        )
      finally
        !pending_tasks |> List.iter Lwt.cancel;
        Lwt.return ()

    method confirm message =
      slave#invoke "confirm" [`String message] (function
        | `String "ok" -> `ok
        | `String "cancel" -> `cancel
        | _ -> raise_safe "Invalid response"
      )

    method use_gui = Some slave
  end

let string_of_ynm = function
  | Yes -> "yes"
  | No -> "no"
  | Maybe -> "maybe"

let try_get_gtk_gui config use_gui =
  let slave = new Zeroinstall.Python.slave config in
  if slave#invoke "check-gui" [`String (string_of_ynm use_gui)] Yojson.Basic.Util.to_bool |> Lwt_main.run then (
    Some (new gui_ui slave)
  ) else (
    None
  )

let () =
  log_info "Initialising GTK GUI";
  Zeroinstall.Gui.register_plugin try_get_gtk_gui
