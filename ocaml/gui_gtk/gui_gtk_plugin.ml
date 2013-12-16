(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A GTK GUI plugin *)

open Support.Common

module Python = Zeroinstall.Python
module Ui = Zeroinstall.Ui
module Downloader = Zeroinstall.Downloader

let make_gtk_ui (slave:Python.slave) =
  let config = slave#config in

  let trust_db = new Zeroinstall.Trust.trust_db config in

  object (self : Zeroinstall.Gui.gui_ui)
    val mutable preferences_dialog = None
    val mutable solver_boxes : Solver_box.solver_box list = []

    val mutable n_completed_downloads = 0
    val mutable size_completed_downloads = 0L
    val mutable downloads = []
    val mutable pulse = None

    method monitor dl =
      log_debug "start_monitoring %s" dl.Downloader.url;
      downloads <- dl :: downloads;

      if pulse = None then (
        pulse <- Some (
          try_lwt
            while_lwt downloads <> [] do
              lwt () = Lwt_unix.sleep 0.2 in
              downloads <- downloads |> List.filter (fun dl ->
                if Downloader.is_in_progress dl then true
                else (
                  log_debug "stop_monitoring %s" dl.Downloader.url;
                  let (bytes, _, _) = Lwt_react.S.value dl.Downloader.progress in
                  n_completed_downloads <- n_completed_downloads + 1;
                  size_completed_downloads <- Int64.add size_completed_downloads bytes;
                  false
                )
              );
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
      )

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
          Gtk_utils.async (fun () -> result >> (preferences_dialog <- None; Lwt.return ()));
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

    method run_solver distro downloader ?test_callback ?systray mode reqs ~refresh =
      let fetcher = new Zeroinstall.Fetch.fetcher config trust_db distro downloader (lazy (self :> Ui.ui_handler)) in
      let abort_all_downloads () =
        downloads |> List.iter (fun dl ->
          Gtk_utils.async dl.Downloader.cancel
        ) in
      let box = Solver_box.run_solver config self trust_db fetcher ~abort_all_downloads ?test_callback ?systray mode reqs ~refresh in
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

    method open_cache_explorer = Cache_explorer_box.open_cache_explorer config
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
