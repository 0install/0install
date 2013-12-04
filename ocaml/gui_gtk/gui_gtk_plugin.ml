(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A GTK GUI plugin *)

open Support.Common

module Ui = Zeroinstall.Ui
module Python = Zeroinstall.Python

let make_gtk_ui (slave:Python.slave) =
  let downloads = Hashtbl.create 10 in

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

  let trust_db = new Zeroinstall.Trust.trust_db slave#config in

  object (_ : Zeroinstall.Gui.gui_ui)
    val mutable preferences_dialog = None

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

    (* TODO: pass ~parent (once we have one) *)
    method confirm_keys feed_url infos = Trust_box.confirm_keys slave#config trust_db feed_url infos

    method show_preferences =
      match preferences_dialog with
      | Some (dialog, result) -> dialog#present (); result
      | None ->
          let recalculate () = Python.async (fun () -> slave#invoke "gui-recalculate" [] Python.expect_null) in
          let dialog, result = Preferences_box.show_preferences slave#config trust_db ~recalculate in
          preferences_dialog <- Some (dialog, result);
          dialog#show ();
          Python.async (fun () -> result >> (preferences_dialog <- None; Lwt.return ()));
          result

    method confirm message =
      slave#invoke "confirm" [`String message] (function
        | `String "ok" -> `ok
        | `String "cancel" -> `cancel
        | _ -> raise_safe "Invalid response"
      )

    method config = slave#config
    method invoke = slave#invoke
  end

let string_of_ynm = function
  | Yes -> "yes"
  | No -> "no"
  | Maybe -> "maybe"

(* If this raises an exception, gui.ml will log it and continue without the GUI. *)
let try_get_gtk_gui config use_gui =
  (* Initializes GTK. *)
  ignore (GMain.init ());

  let slave = new Zeroinstall.Python.slave config in
  if slave#invoke "check-gui" [`String (string_of_ynm use_gui)] Yojson.Basic.Util.to_bool |> Lwt_main.run then (
    Some (make_gtk_ui slave)
  ) else (
    None
  )

let () =
  log_info "Initialising GTK GUI";
  Zeroinstall.Gui.register_plugin try_get_gtk_gui
