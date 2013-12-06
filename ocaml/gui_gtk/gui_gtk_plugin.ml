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

  let recalculate () = Python.async (fun () -> slave#invoke "gui-recalculate" [] Python.expect_null) in

  object (_ : Zeroinstall.Gui.gui_ui)
    val mutable preferences_dialog = None
    val mutable component_boxes = StringMap.empty
    val mutable last_update = None

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

    method report_error ex = Alert_box.report_error ex

    method show_preferences =
      match preferences_dialog with
      | Some (dialog, result) -> dialog#present (); result
      | None ->
          let dialog, result = Preferences_box.show_preferences slave#config trust_db ~recalculate in
          preferences_dialog <- Some (dialog, result);
          dialog#show ();
          Python.async (fun () -> result >> (preferences_dialog <- None; Lwt.return ()));
          result

    method show_component ~driver iface ~select_versions_tab =
      match StringMap.find iface component_boxes with
      | Some box -> box#dialog#present ()
      | None ->
          let box = Component_box.create slave#config trust_db driver iface ~recalculate ~select_versions_tab in
          component_boxes <- component_boxes |> StringMap.add iface box;
          box#dialog#connect#destroy ~callback:(fun () -> component_boxes <- component_boxes |> StringMap.remove iface) |> ignore;
          last_update |> if_some box#update;
          box#dialog#show ()

    method update reqs results : unit =
      last_update <- Some (reqs, results);
      component_boxes |> StringMap.iter (fun _iface box ->
        box#update (reqs, results)
      )

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
