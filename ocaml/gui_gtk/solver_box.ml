(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main GUI window showing the progress of a solve. *)

open Support.Common

module Python = Zeroinstall.Python
module Feed_url = Zeroinstall.Feed_url
module Driver = Zeroinstall.Driver
module Requirements = Zeroinstall.Requirements
module U = Support.Utils
module Ui = Zeroinstall.Ui

let main_window_help = Help_box.create "0install Help" [
("Overview",
"A program is made up of many different components, typically written by different \
groups of people. Each component is available in multiple versions. 0install is \
used when starting a program. Its job is to decide which version of each required \
component to use.
\n\
0install starts with the program you want to run (e.g. 'The Gimp') and chooses an \
implementation (e.g. 'The Gimp 2.2.0'). However, this implementation \
will in turn depend on other components, such as 'GTK' (which draws the menus \
and buttons). Thus, 0install must choose implementations of \
each dependency (each of which may require further components, and so on).");

("List of components",
"The main window displays all these components, and the version of each chosen \
implementation. The top-most one represents the program you tried to run, and each direct \
child is a dependency. The 'Fetch' column shows the amount of data that needs to be \
downloaded, or '(cached)' if it is already on this computer.
\n\
If you are happy with the choices shown, click on the Download (or Run) button to \
download (and run) the program.");

("Choosing different versions",
"To control which implementations (versions) are chosen you can click on Preferences \
and adjust the network policy and the overall stability policy. These settings affect \
all programs run using 0install.
\n\
Alternatively, you can edit the policy of an individual component by clicking on the \
button at the end of its line in the table and choosing \"Show Versions\" from the menu. \
See that dialog's help text for more information.");

("Reporting bugs",
"To report a bug, right-click over the component which you think contains the problem \
and choose 'Report a Bug...' from the menu. If you don't know which one is the cause, \
choose the top one (i.e. the program itself). The program's author can reassign the \
bug if necessary, or switch to using a different version of the library.");

("The cache",
"Each version of a program that is downloaded is stored in the 0install cache. This \
means that it won't need to be downloaded again each time you run the program. The \
\"0install store manage\" command can be used to view the cache.");
]

class type solver_box =
  object
    method recalculate : unit
    method result : [`Aborted_by_user | `Success of Support.Qdom.element ] Lwt.t
    method ensure_main_window : GWindow.window_skel Lwt.t
    method update_download_status : n_completed_downloads:int -> size_completed_downloads:Int64.t -> Ui.download StringMap.t -> unit
    method impl_added_to_store : unit
  end

let run_solver config (gui:Zeroinstall.Gui.gui_ui) trust_db driver ~abort_all_downloads ?test_callback ?(systray=false) mode reqs ~refresh : solver_box =
  let refresh = ref refresh in
  let component_boxes = ref StringMap.empty in

  let feed_provider = ref (new Zeroinstall.Feed_provider_impl.feed_provider config driver#distro) in

  let original_solve = Zeroinstall.Solver.solve_for config !feed_provider reqs in
  let original_selections =
    match original_solve with
    | (false, _) -> StringMap.empty
    | (true, results) -> Zeroinstall.Selections.make_selection_map results#get_selections in

  let results = ref original_solve in

  let report_bug iface =
    let run_test = test_callback |> pipe_some (fun test_callback ->
      Some (fun () -> Zeroinstall.Gui.run_test config driver#distro test_callback !results)
    ) in
    Bug_report_box.create ?run_test ?last_error:!Alert_box.last_error config ~iface ~results:!results in

  let need_recalculate = ref (Lwt.wait ()) in
  let recalculate ~force =
    if force then refresh := true;
    let thread, waker = !need_recalculate in
    if Lwt.state thread = Lwt.Sleep then Lwt.wakeup waker () in

  let show_component iface ~select_versions_tab =
    match StringMap.find iface !component_boxes with
    | Some box -> box#dialog#present ()
    | None ->
        let box = Component_box.create config trust_db driver reqs iface ~recalculate ~select_versions_tab ~feed_provider ~results in
        component_boxes := !component_boxes |> StringMap.add iface box;
        box#dialog#connect#destroy ~callback:(fun () -> component_boxes := !component_boxes |> StringMap.remove iface) |> ignore;
        box#update;
        box#dialog#show () in

  let dialog = GWindow.dialog ~title:"0install" () in
  let vbox = GPack.vbox ~packing:(dialog#vbox#pack ~expand:true) ~border_width:5 ~spacing:4 () in

  (* The optional message *)
  reqs.Requirements.message |> if_some (fun message ->
    let label = GMisc.label ~packing:vbox#pack ~xalign:0.0 ~line_wrap:true ~text:message () in
    let font = Pango.Font.copy label#misc#pango_context#font_description in
    Pango.Font.set_weight font `BOLD;
    label#misc#modify_font font
  );

  (* The component tree view *)
  let icon_cache = Icon_cache.create ~downloader:driver#fetcher#downloader config in
  let component_tree = Component_tree.build_tree_view config ~parent:dialog ~packing:(vbox#pack ~expand:true)
    ~icon_cache ~show_component ~report_bug ~recalculate ~feed_provider ~original_selections ~results in
  component_tree#set_update_icons !refresh;

  (* The Refresh / Stop bar *)
  let refresh_bar = GPack.hbox ~packing:vbox#pack ~spacing:4 () in
  let refresh_button = Gtk_utils.mixed_button ~packing:refresh_bar#pack ~use_mnemonic:true ~stock:`REFRESH ~label:"Re_fresh all now" () in
  refresh_button#connect#clicked ~callback:(fun () -> recalculate ~force:true) |> ignore;
  refresh_button#misc#set_tooltip_text "Check all the components for updates.";

  let progress_area = GPack.hbox ~packing:(refresh_bar#pack ~expand:true) ~show:false () in
  let progress_bar = GRange.progress_bar ~packing:(progress_area#pack ~expand:true ~padding:4) () in
  let stop_button = GButton.button ~packing:progress_area#pack ~stock:`STOP () in
  stop_button#connect#clicked ~callback:abort_all_downloads |> ignore;

  (* Dialog buttons *)
  dialog#add_button_stock `HELP `HELP;
  dialog#add_button_stock `PREFERENCES `PREFERENCES;
  let actions = dialog#action_area in
  actions#children |> List.iter (fun button -> actions#set_child_secondary button true);

  dialog#add_button_stock `CANCEL `CANCEL;

  let systray_icon = ref None in

  let user_response, set_user_response = Lwt.wait () in

  (* No add_action_widget, so have to do this manually. *)
  let action = match mode with
  | `Select_only -> "Select"
  | `Download_only -> "Download"
  | `Select_for_run -> "Run" in
  let ok_button = GButton.toggle_button ~packing:dialog#action_area#pack () in
  ok_button#misc#set_can_default true;
  ok_button#misc#set_sensitive false;
  Gtk_utils.stock_label ~packing:ok_button#add ~stock:`EXECUTE ~label:action ();

  dialog#connect#response ~callback:(function
    | `HELP -> main_window_help#display
    | `PREFERENCES -> Gtk_utils.async ~parent:dialog (fun () -> gui#show_preferences)
    | `DELETE_EVENT | `CANCEL ->
        Lwt.wakeup set_user_response `aborted_by_user
  ) |> ignore;

  dialog#set_default_size
    ~width:(Gdk.Screen.width () * 2 / 5)
    ~height:300;

  if systray then (
    let icon = GMisc.status_icon_from_icon_name "zeroinstall" in
    icon#set_tooltip (Printf.sprintf "Checking for updates for %s" reqs.Requirements.interface_uri);
    let clicked, set_clicked = Lwt.wait () in
    let switch_to_window () =
      dialog#show ();
      ok_button#set_active false;
      icon#set_visible false;
      systray_icon := None;
      Lwt.wakeup set_clicked () in
    icon#connect#activate ~callback:switch_to_window |> ignore;
    dialog#misc#realize ();     (* Make busy pointer work, even with --systray *)

    let set_blinking () =
      Gtk_utils.async (fun () ->
        (* If the icon isn't embedded yet, give it a chance first... *)
        lwt () = if not icon#is_embedded then Lwt_unix.sleep 0.5 else Lwt.return () in
        if icon#is_embedded then
          icon#set_blinking true
        else (
          log_info "No system-tray support, so opening main window immediately";
          switch_to_window ()
        );
        Lwt.return ()
      ) in

    systray_icon := Some (icon, clicked, set_blinking);
  ) else (
    dialog#show ();
  );

  let report_error ex =
    log_info ~ex "Reporting error to user";
    let blocker =
      match !systray_icon with
      | Some (icon, clicked, set_blinking) ->
          set_blinking ();
          icon#set_tooltip (Printf.sprintf "%s\n(click for details)" (Printexc.to_string ex));
          clicked
      | None -> Lwt.return () in
    Gtk_utils.async (fun () ->
      lwt () = blocker in
      Alert_box.report_error ~parent:dialog ex;
      Lwt.return ()
    ) in

  (* Handling the Select/Download/Run toggle button *)
  ok_button#connect#toggled ~callback:(fun () ->
    log_info "OK button => %b" ok_button#active;
    let on_success () =
      (* Downloads done - check button is still pressed *)
      if ok_button#active then (
        abort_all_downloads ();
        Lwt.wakeup set_user_response `ok;
      );
      Lwt.return () in
    let (ready, results) = !results in
    if ok_button#active && ready then (
      (* Start the downloads; run when complete *)
      abort_all_downloads ();
      Gtk_utils.async ~parent:dialog (fun () ->
        try_lwt
          match mode with
          | `Select_only -> on_success ()
          | `Download_only | `Select_for_run ->
              let sels = results#get_selections in
              match_lwt driver#download_selections ~include_packages:true ~feed_provider:!feed_provider sels with
              | `aborted_by_user -> ok_button#set_active false; Lwt.return ()
              | `success -> on_success ()
        with Safe_exception _ as ex ->
          ok_button#set_active false;
          report_error ex;
          Lwt.return ()
      )
    )
  ) |> ignore;

  let box_open_time = Unix.gettimeofday () in

  (* Run a solve-with-downloads immediately, and every time the user clicks Refresh. *)
  let refresh_loop =
    let watcher =
      object (_ : Ui.watcher)
        method update ((ready, new_results), new_fp) =
          feed_provider := new_fp;
          results := (ready, new_results);

          ok_button#misc#set_sensitive ready;

          !component_boxes |> StringMap.iter (fun _iface box ->
            box#update
          );

          component_tree#update

        method report feed_url msg =
          let msg = Printf.sprintf "Feed '%s': %s" (Feed_url.format_url feed_url) msg in
          report_error (Safe_exception (msg, ref []))
      end in

    while_lwt Lwt.state user_response = Lwt.Sleep do
      need_recalculate := Lwt.wait ();
      refresh_button#misc#set_sensitive false;
      let force = !refresh in
      refresh := false;
      lwt (ready, _, _) = driver#solve_with_downloads ~watcher reqs ~force ~update_local:true in
      if Unix.gettimeofday () < box_open_time +. 1. then ok_button#grab_default ();
      component_tree#highlight_problems;

      !systray_icon |> if_some (fun (icon, _clicked, set_blinking) ->
        if icon#visible && icon#is_embedded then (
          if ready then (
            icon#set_tooltip (Printf.sprintf "Downloading updates for %s" reqs.Requirements.interface_uri);
            ok_button#set_active true
          ) else (
            (* Should already be reporting an error, but blink it again just in case *)
            set_blinking ();
          )
        )
      );

      (* Wait for user choice or refresh request *)
      refresh_button#misc#set_sensitive true;
      component_tree#set_update_icons true;
      fst !need_recalculate
    done in

  let result =
    (* Wait for user to click Cancel or Run *)
    lwt response = user_response in
    abort_all_downloads ();
    Lwt.cancel refresh_loop;

    match response with
    | `ok ->
        let (ready, results) = !results in
        assert ready;
        `Success results#get_selections |> Lwt.return
    | `aborted_by_user -> `Aborted_by_user |> Lwt.return in

  let default_cursor = Gdk.Cursor.create `LEFT_PTR in

  (* We used to have a nice animated pointer+watch, but it stopped working at some
   * point (even in the Python).
   * See: http://mail.gnome.org/archives/gtk-list/2007-May/msg00100.html *)
  let busy_cursor = Gdk.Cursor.create `WATCH in

  object
    method recalculate = recalculate ~force:false
    method result = result

    (* Return the dialog window. If we're in systray mode, blink the icon and wait for the user
     * to click on it first. *)
    method ensure_main_window =
      match !systray_icon with
      | None -> Lwt.return (dialog :> GWindow.window_skel)
      | Some (icon, clicked, set_blinking) ->
          set_blinking ();
          icon#set_tooltip "Interaction needed - click to open main window";
          lwt () = clicked in      (* Wait for user to click on the icon *)
          lwt () = Lwt_unix.sleep 0.5 in
          Lwt.return (dialog :> GWindow.window_skel)

    (* Called at regular intervals while there are downloads in progress, and once at the end.
     * Update the display. *)
    method update_download_status ~n_completed_downloads ~size_completed_downloads downloads =
      if Lwt.state user_response = Lwt.Sleep then (
        (* (dialog is still in use) *)
        component_tree#update_download_status downloads;

        if StringMap.is_empty downloads then (
          progress_area#misc#hide ();
          Gdk.Window.set_cursor dialog#misc#window default_cursor
        ) else if not (progress_area#misc#get_flag `VISIBLE) then (
          progress_area#misc#show ();
          Gdk.Window.set_cursor dialog#misc#window busy_cursor
        );

        (* Calculate stats: completed downloads + downloads in progress *)
        let total_so_far = ref size_completed_downloads in
        let total_expected = ref size_completed_downloads in
        let n_downloads = ref n_completed_downloads in
        let any_known = ref false in

        downloads |> StringMap.iter (fun _id dl ->
          let (so_far, expected) = Lwt_react.S.value dl.Ui.progress in
          total_so_far := Int64.add !total_so_far so_far;
          if expected <> None then any_known := true;
          (* Guess about 4K for feeds/icons *)
          let expected = expected |? lazy (if Int64.compare so_far 4096L > 0 then so_far else 4096L) in
          total_expected := Int64.add !total_expected expected;
          incr n_downloads
        );

        let progress_text = Printf.sprintf "%s / %s" (U.format_size !total_so_far) (U.format_size !total_expected) in
        if !n_downloads = 1 then
          progress_bar#set_text (Printf.sprintf "Downloading one file (%s)" progress_text)
        else
          progress_bar#set_text (Printf.sprintf "Downloading %d files (%s)" !n_downloads progress_text);

        if !total_expected = 0L || (!n_downloads < 2 && not !any_known) then (
          progress_bar#pulse ()
        ) else (
          progress_bar#set_fraction (Int64.to_float !total_so_far /. Int64.to_float !total_expected)
        );
      )

    method impl_added_to_store = component_tree#update
  end
