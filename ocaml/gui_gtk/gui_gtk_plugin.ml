(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A GTK GUI plugin *)

open Support.Common

module Python = Zeroinstall.Python
module Ui = Zeroinstall.Ui

let make_gtk_ui (slave:Python.slave) =
  let config = slave#config in

  let trust_db = new Zeroinstall.Trust.trust_db config in

  object (self : Zeroinstall.Gui.gui_ui)
    val mutable preferences_dialog = None
    val mutable solver_boxes : Solver_box.solver_box list = []

    val mutable n_completed_downloads = 0
    val mutable size_completed_downloads = 0L
    val mutable downloads = StringMap.empty
    val mutable pulse = None

    method start_monitoring ~id dl =
      log_debug "start_monitoring %s" id;
      downloads <- downloads |> StringMap.add id dl;

      if pulse = None then (
        pulse <- Some (
          try_lwt
            while_lwt not (StringMap.is_empty downloads) do
              lwt () = Lwt_unix.sleep 0.2 in
              solver_boxes |> List.iter (fun box -> box#update_download_status ~n_completed_downloads ~size_completed_downloads downloads);
              Lwt.return ()
            done
          with ex ->
            log_warning ~ex "GUI update failed";
            Lwt.return ()
          finally
            pulse <- None;
            (* We do this here, rather than in [stop_monitoring], to introduce a delay,
             * since we often start a new download immediately after another one finished and
             * we don't want to reset in that case. *)
            n_completed_downloads <- 0;
            size_completed_downloads <- 0L;
            Lwt.return ()
        )
      );
      Lwt.return ()

    method stop_monitoring ~id =
      log_debug "stop_monitoring %s" id;
      let dl = downloads |> StringMap.find_safe id in
      n_completed_downloads <- n_completed_downloads + 1;
      size_completed_downloads <- Int64.add size_completed_downloads (fst (Lwt_react.S.value dl.Ui.progress));
      downloads <- downloads |> StringMap.remove id;
      Lwt.return ()

    method impl_added_to_store =
      solver_boxes |> List.iter (fun box -> box#impl_added_to_store)

    method confirm_keys feed_url infos =
      let box = List.hd solver_boxes in
      lwt parent = box#ensure_main_window in
      Trust_box.confirm_keys ~parent config trust_db feed_url infos

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
      let box = List.hd solver_boxes in
      lwt parent = box#ensure_main_window in

      let box = GWindow.message_dialog
        ~parent
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
      let abort_all_downloads () =
        downloads |> StringMap.iter (fun _id dl ->
          Python.async dl.Ui.cancel
        ) in
      let box = Solver_box.run_solver config self trust_db driver ~abort_all_downloads ?test_callback ?systray mode reqs ~refresh in
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

(* If this raises an exception, gui.ml will log it and continue without the GUI. *)
let try_get_gtk_gui config _use_gui =
  (* Initializes GTK. *)
  ignore (GMain.init ());

  let slave = new Zeroinstall.Python.slave config in
  Some (make_gtk_ui slave)

let () =
  log_info "Initialising GTK GUI";
  Zeroinstall.Gui.register_plugin try_get_gtk_gui
