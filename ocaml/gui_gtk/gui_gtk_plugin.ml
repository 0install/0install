(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A GTK GUI plugin *)

open Support.Common

module Python = Zeroinstall.Python

let make_gtk_ui (slave:Python.slave) =
  let config = slave#config in
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

  let trust_db = new Zeroinstall.Trust.trust_db config in

  object (self : Zeroinstall.Gui.gui_ui)
    val mutable preferences_dialog = None
    val mutable solver_boxes : Solver_box.solver_box list = []

    method start_monitoring ~id dl =
      let open Zeroinstall.Ui in
      let size =
        match snd @@ Lwt_react.S.value dl.progress with
        | None -> `Null
        | Some size -> `Float (Int64.to_float size) in
      let hint =
        match dl.hint with
        | None -> `Null
        | Some hint -> `String hint in
      let details = `Assoc [
        ("url", `String dl.url);
        ("hint", hint);
        ("size", size);
        ("tempfile", `String id);
      ] in
      let updates = dl.progress |> Lwt_react.S.map_s (fun (sofar, total) ->
        if Hashtbl.mem downloads id then (
          let sofar = Int64.to_float sofar in
          let total =
            match total with
            | None -> `Null
            | Some total -> `Float (Int64.to_float total) in
          slave#invoke "set-progress" [`String id; `Float sofar; total] Python.expect_null
        ) else Lwt.return ()
      ) in
      Hashtbl.add downloads id (dl.cancel, updates);     (* (store updates to prevent GC) *)
      slave#invoke "start-monitoring" [details] Python.expect_null

    method stop_monitoring ~id =
      Hashtbl.remove downloads id;
      slave#invoke "stop-monitoring" [`String id] Python.expect_null

    method impl_added_to_store = ()

    (* TODO: pass ~parent (once we have one) *)
    method confirm_keys feed_url infos = Trust_box.confirm_keys config trust_db feed_url infos

    method report_error ex = Alert_box.report_error ex

    method private recalculate () =
      solver_boxes |> List.iter (fun box -> box#recalculate)

    method show_preferences =
      match preferences_dialog with
      | Some (dialog, result) -> dialog#present (); result
      | None ->
          let dialog, result = Preferences_box.show_preferences config trust_db ~recalculate:self#recalculate in
          preferences_dialog <- Some (dialog, result);
          dialog#show ();
          Python.async (fun () -> result >> (preferences_dialog <- None; Lwt.return ()));
          result

    method confirm message =
      (* TODO: in systray mode, open the main window now *)
      let box = GWindow.message_dialog
        (* ~parent todo *)
        ~message_type:`QUESTION
        ~title:"Confirm"
        ~message
        ~buttons:GWindow.Buttons.ok_cancel
        () in
      let result, set_result = Lwt.wait () in
      box#set_default_response `OK;
      box#connect#response ~callback:(fun response ->
        box#destroy ();
        Lwt.wakeup set_result (
          match response with
          | `OK -> `ok
          | `CANCEL | `DELETE_EVENT -> `cancel
        )
      ) |> ignore;
      box#show ();
      result

    method run_solver driver ?test_callback ?systray mode reqs ~refresh =
      let box = Solver_box.run_solver config self slave trust_db driver ?test_callback ?systray mode reqs ~refresh in
      solver_boxes <- box :: solver_boxes;
      try_lwt
        box#result
      finally
        solver_boxes <- solver_boxes |> List.filter ((<>) box);
        Lwt.return ()

    method open_app_list_box =
      slave#invoke "open-app-list-box" [] Zeroinstall.Python.expect_null

    method open_add_box url =
      slave#invoke "open-add-box" [`String url] Zeroinstall.Python.expect_null

    method open_cache_explorer = Cache_explorer_box.open_cache_explorer config slave
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
