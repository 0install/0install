(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A GTK GUI plugin *)

open Support.Common
open Zeroinstall.General

let make_gtk_ui config =
  let trust_db = new Zeroinstall.Trust.trust_db config in

  let batch_ui = lazy (new Zeroinstall.Console.batch_ui) in

  let tools = (* TODO: move this out of the plugin *)
    let packagekit = lazy (Zeroinstall.Packagekit.make (Support.Locale.LangMap.choose config.langs |> fst)) in
    let distro = Zeroinstall.Distro_impls.get_host_distribution ~packagekit config in
    let download_pool = Zeroinstall.Downloader.make_pool ~max_downloads_per_site:2 in
    object
      method config = config
      method distro = distro
      method make_fetcher watcher = Zeroinstall.Fetch.make config trust_db distro download_pool watcher
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
          let dialog, result = Preferences_box.make config trust_db ~recalculate:self#recalculate in
          preferences_dialog <- Some (dialog, result);
          dialog#show ();
          Gtk_utils.async (fun () -> result >|= fun () -> preferences_dialog <- None);
          result

    method show_preferences = Some (self#show_preferences_internal)

    method run_solver tools ?systray mode reqs ~refresh =
      let solver_promise, set_solver = Lwt.wait () in
      let watcher = Gui_progress.make_watcher solver_promise tools ~trust_db reqs in
      let show_preferences () = self#show_preferences_internal in
      let box = Solver_box.run_solver ~show_preferences ~trust_db tools ?systray mode reqs ~refresh watcher in
      Lwt.wakeup set_solver box;
      solver_boxes <- box :: solver_boxes;
      Lwt.finalize
        (fun () -> box#result)
        (fun () ->
          solver_boxes <- solver_boxes |> List.filter ((<>) box);
          Lwt.return ()
        )

    method open_app_list_box =
      App_list_box.create config ~gui:self ~tools ~add_app:self#open_add_box

    method open_add_box url = Add_box.create ~gui:self ~tools url 

    method open_cache_explorer = Cache_explorer_box.open_cache_explorer config

    method watcher =
      log_info "GUI download not in the context of any window";
      (Lazy.force batch_ui)#watcher
  end

(* If this raises an exception, gui.ml will log it and continue without the GUI. *)
let try_get_gtk_gui config =
  log_info "Switching to GLib mainloop...";

  (* Install Lwt<->Glib integration.
   * LWT <= 2.4.4 is buggy (https://github.com/ocsigen/lwt/issues/25) so we have
   * to be careful... *)
  if config.system#platform.Platform.os = "Linux" then (
     (* On Linux:
      * - lwt_into_glib mode hangs for LWT <= 2.4.4
      * - glib_into_lwt works on all versions, so use that *)
    Lwt_glib.install ~mode:`glib_into_lwt ()
  ) else (
    (* Otherwise, glib_into_lwt never works, so use lwt_into_glib (and require LWT > 2.4.4). *)
    Lwt_glib.install ~mode:`lwt_into_glib ()
  );

  (* Initializes GTK. *)
  ignore (GMain.init ());
  Some (make_gtk_ui config)

let () =
  log_info "Initialising GTK GUI";
  Zeroinstall.Gui.register_plugin try_get_gtk_gui
