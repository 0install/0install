(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A GTK GUI plugin *)

open Support.Common

module Python = Zeroinstall.Python
module Ui = Zeroinstall.Ui
module Downloader = Zeroinstall.Downloader

let make_gtk_ui config =
  let trust_db = new Zeroinstall.Trust.trust_db config in

  let batch_ui = lazy (new Zeroinstall.Console.batch_ui) in

  let tools = (* TODO: move this out of the plugin *)
    let distro = Zeroinstall.Distro_impls.get_host_distribution config in
    let download_pool = Zeroinstall.Downloader.make_pool ~max_downloads_per_site:2 in
    object
      method config = config
      method distro = distro
      method make_fetcher watcher = new Zeroinstall.Fetch.fetcher config trust_db distro download_pool watcher
    end in

  object (self : Zeroinstall.Ui.ui_handler)
    val mutable preferences_dialog = None
    val mutable solver_boxes : Solver_box.solver_box list = []

    method private recalculate () =
      solver_boxes |> List.iter (fun box -> box#recalculate)

    method private show_preferences_internal =
      match preferences_dialog with
      | Some (dialog, result) -> dialog#present (); result
      | None ->
          let dialog, result = Preferences_box.show_preferences config trust_db ~recalculate:self#recalculate in
          preferences_dialog <- Some (dialog, result);
          dialog#show ();
          Gtk_utils.async (fun () -> result >> (preferences_dialog <- None; Lwt.return ()));
          result

    method show_preferences = Some (self#show_preferences_internal)

    method run_solver tools ?test_callback ?systray mode reqs ~refresh =
      let solver_promise, set_solver = Lwt.wait () in
      let watcher = Gui_progress.make_watcher solver_promise tools ~trust_db reqs in
      let show_preferences () = self#show_preferences_internal in
      let box = Solver_box.run_solver ~show_preferences ~trust_db tools ?test_callback ?systray mode reqs ~refresh watcher in
      Lwt.wakeup set_solver box;
      solver_boxes <- box :: solver_boxes;
      try_lwt
        box#result
      finally
        solver_boxes <- solver_boxes |> List.filter ((<>) box);
        Lwt.return ()

    method open_app_list_box =
      App_list_box.create config ~gui:self ~tools ~add_app:self#open_add_box

    method open_add_box url = Add_box.create ~gui:self ~tools url 

    method open_cache_explorer = Cache_explorer_box.open_cache_explorer config

    method watcher =
      log_warning "GUI download not in the context of any window!";
      (Lazy.force batch_ui)#watcher
  end

(* If this raises an exception, gui.ml will log it and continue without the GUI. *)
let try_get_gtk_gui config _use_gui =
  (* Initializes GTK. *)
  ignore (GMain.init ());
  Some (make_gtk_ui config)

let () =
  log_info "Initialising GTK GUI";
  Zeroinstall.Gui.register_plugin try_get_gtk_gui
