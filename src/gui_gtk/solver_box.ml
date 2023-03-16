(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main GUI window showing the progress of a solve. *)

open Support
open Support.Common
open Gtk_common

module Feed_url = Zeroinstall.Feed_url
module Driver = Zeroinstall.Driver
module Requirements = Zeroinstall.Requirements
module U = Support.Utils
module Progress = Zeroinstall.Progress
module Downloader = Zeroinstall.Downloader
module RoleMap = Zeroinstall.Solver.Output.RoleMap

let main_window_help = Help_box.create "0install Help" [
("Overview",
"A program is made up of many different components, typically written by different \
groups of people. Each component is available in multiple versions. 0install is \
used when starting a program. Its job is to decide which version of each required \
component to use.\n\
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
downloaded, or '(cached)' if it is already on this computer.\n\
\n\
If you are happy with the choices shown, click on the Download (or Run) button to \
download (and run) the program.");

("Choosing different versions",
"To control which implementations (versions) are chosen you can click on Preferences \
and adjust the network policy and the overall stability policy. These settings affect \
all programs run using 0install.\n\
\n\
Alternatively, you can edit the policy of an individual component by clicking on the \
button at the end of its line in the table and choosing \"Show Versions\" from the menu. \
See that dialog's help text for more information.");

("The cache",
"Each version of a program that is downloaded is stored in the 0install cache. This \
means that it won't need to be downloaded again each time you run the program. The \
\"0install store manage\" command can be used to view the cache.");
]

class type solver_box =
  object
    method recalculate : unit
    method result : [`Aborted_by_user | `Success of Zeroinstall.Selections.t ] Lwt.t
    method ensure_main_window : GWindow.window_skel Lwt.t
    method update : unit
    method update_download_status : n_completed_downloads:int -> size_completed_downloads:Int64.t -> Downloader.download list -> unit
    method impl_added_to_store : unit
    method report_error : exn -> unit
  end

type widgets = {
  dialog : [`HELP |`PREFERENCES | `CANCEL | `DELETE_EVENT] GWindow.dialog;
  refresh_button : GButton.button;

  swin : GBin.scrolled_window;

  progress_bar : GRange.progress_bar;
  progress_area : GPack.box;
  progress_info : GMisc.label;
  stop_button : GButton.button;

  ok_button : GButton.toggle_button;

  systray_icon : Tray_icon.tray_icon;
}

let make_dialog opt_message mode ~systray =
  let dialog = GWindow.dialog ~title:"0install" () in
  let vbox = GPack.vbox ~packing:(dialog#vbox#pack ~expand:true) ~border_width:5 ~spacing:4 () in

  (* The optional message *)
  opt_message |> if_some (fun message ->
    let label = GMisc.label ~packing:vbox#pack ~xalign:0.0 ~line_wrap:true ~text:message () in
    let font = label#misc#pango_context#font_description#copy in
    Pango.Font.set_weight font#fd `BOLD;
    label#misc#modify_font font
  );

  (* The component tree view *)
  let swin = GBin.scrolled_window
    ~packing:(vbox#pack ~expand:true)
    ~hpolicy:`AUTOMATIC
    ~vpolicy:`AUTOMATIC
    ~shadow_type:`IN
    () in

  let progress_bar = GRange.progress_bar ~packing:(vbox#pack ~expand:false ~padding:0) () in

  (* The Refresh / Stop bar *)
  let refresh_bar = GPack.hbox ~packing:vbox#pack ~spacing:4 () in
  let refresh_button = Gtk_utils.mixed_button ~packing:refresh_bar#pack ~use_mnemonic:true ~stock:`REFRESH ~label:"Re_fresh all now" () in
  refresh_button#misc#set_tooltip_text "Check all the components for updates.";

  let progress_area = GPack.hbox ~packing:(refresh_bar#pack ~expand:true) ~show:false () in
  let progress_info = GMisc.label ~packing:(progress_area#pack ~expand:true) () in
  let stop_button = GButton.button ~packing:progress_area#pack ~stock:`STOP () in

  (* Dialog buttons *)
  dialog#add_button_stock `HELP `HELP;
  dialog#add_button_stock `PREFERENCES `PREFERENCES;
  let actions = dialog#action_area in
  actions#set_border_width 4;
  actions#children |> List.iter (fun button -> actions#set_child_secondary button true);

  dialog#add_button_stock `CANCEL `CANCEL;

  (* No add_action_widget, so have to do this manually. *)
  let action = match mode with
  | `Select_only -> "Select"
  | `Download_only -> "Download"
  | `Select_for_run -> "Run" in
  let ok_button = GButton.toggle_button ~packing:dialog#action_area#pack () in
  ok_button#misc#set_can_default true;
  ok_button#misc#set_sensitive false;
  Gtk_utils.stock_label ~packing:ok_button#add ~stock:`EXECUTE ~label:action ();

  dialog#set_default_size
    ~width:(Gdk.Screen.width () * 2 / 5)
    ~height:300;

  let systray_icon = new Tray_icon.tray_icon systray in

  {dialog; refresh_button; progress_area; progress_info; stop_button; ok_button; swin; progress_bar; systray_icon}

let run_solver ~show_preferences ~trust_db tools ?(systray=false) mode reqs ~refresh watcher : solver_box =
  let config = tools#config in
  let refresh = ref refresh in
  let component_boxes = ref RoleMap.empty in

  let need_recalculate = ref (Lwt.wait ()) in
  let recalculate ~force =
    if force then refresh := true;
    let thread, waker = !need_recalculate in
    if Lwt.state thread = Lwt.Sleep then Lwt.wakeup waker () in

  let fetcher = tools#make_fetcher (watcher :> Zeroinstall.Progress.watcher) in
  let icon_cache = Icon_cache.create ~fetcher config in

  let user_response, set_user_response = Lwt.wait () in

  let widgets = make_dialog reqs.Requirements.message mode ~systray in

  let dialog = widgets.dialog in
  widgets.refresh_button#connect#clicked ==> (fun () -> recalculate ~force:true);
  widgets.stop_button#connect#clicked ==> (fun () -> watcher#abort_all_downloads);

  widgets.dialog#connect#response ==> (function
    | `HELP -> main_window_help#display
    | `PREFERENCES -> Gtk_utils.async ~parent:dialog show_preferences
    | `DELETE_EVENT | `CANCEL ->
        Lwt.wakeup set_user_response `Aborted_by_user
  );

  (* If a system tray icon was requested, create one. Otherwise, show the main window. *)
  if systray then (
    widgets.systray_icon#set_tooltip (Printf.sprintf "Checking for updates for %s" reqs.Requirements.interface_uri);
    dialog#misc#realize ();     (* Make busy pointer work, even with --systray *)
  ) else (
    dialog#show ()
  );

  (* If you need to show a dialog box after the main window is open, wait for this. *)
  let main_window_open =
    if systray then (
      widgets.systray_icon#clicked >>= fun () ->
      widgets.dialog#show ();
      widgets.ok_button#set_active false;
      Lwt_unix.sleep 0.5
    ) else Lwt.return () in

  let report_error ex =
    log_info ~ex "Reporting error to user";
    Gtk_utils.async (fun () ->
      widgets.systray_icon#set_blinking (Some (Printf.sprintf "%s\n(click for details)" (Printexc.to_string ex)));
      main_window_open >|= fun () ->
      Alert_box.report_error ~parent:dialog ex
    ) in

  (* Connect up the component tree view *)
  let show_component role ~select_versions_tab =
    match RoleMap.find_opt role !component_boxes with
    | Some box -> box#dialog#present ()
    | None ->
        let box = Component_box.create tools ~trust_db reqs role ~recalculate ~select_versions_tab ~watcher in
        component_boxes := !component_boxes |> RoleMap.add role box;
        box#dialog#connect#destroy ==> (fun () -> component_boxes := !component_boxes |> RoleMap.remove role);
        box#update (Some role);
        box#dialog#show () in

  let component_tree = Component_tree.build_tree_view config ~parent:dialog ~packing:widgets.swin#add
    ~icon_cache ~show_component ~recalculate ~watcher in
  component_tree#set_update_icons !refresh;

  (* Handling the Select/Download/Run toggle button *)
  widgets.ok_button#connect#toggled ==> (fun () ->
    log_info "OK button => %b" widgets.ok_button#active;
    let on_success () =
      (* Downloads done - check button is still pressed *)
      if widgets.ok_button#active then (
        watcher#abort_all_downloads;
        Lwt.wakeup set_user_response `Ok;
      );
      Lwt.return () in
    let (ready, results) = watcher#results in
    if widgets.ok_button#active && ready then (
      (* Start the downloads; run when complete *)
      watcher#abort_all_downloads;
      Gtk_utils.async ~parent:dialog (fun () ->
        Lwt.catch
          (fun () ->
             match mode with
             | `Select_only -> on_success ()
             | `Download_only | `Select_for_run ->
               let sels = Zeroinstall.Solver.selections results in
               Driver.download_selections config tools#distro (lazy fetcher) ~include_packages:true ~feed_provider:watcher#feed_provider sels >>= function
               | `Aborted_by_user -> widgets.ok_button#set_active false; Lwt.return ()
               | `Success -> on_success ()
          )
          (function
            | Safe_exn.T _ as ex ->
              widgets.ok_button#set_active false;
              report_error ex;
              Lwt.return ()
            | ex -> Lwt.fail ex
          )
      )
    )
  );

  let box_open_time = Unix.gettimeofday () in

  let result = lazy (
    (* Run a solve-with-downloads immediately, and every time the user clicks Refresh. *)
    let rec refresh_loop () =
      match Lwt.state user_response with
      | Lwt.Sleep ->
        need_recalculate := Lwt.wait ();
        widgets.refresh_button#misc#set_sensitive false;
        let force = !refresh in
        refresh := false;
        Driver.solve_with_downloads config tools#distro fetcher ~watcher reqs ~force ~update_local:true
        >>= fun (ready, _, _) ->
        if Unix.gettimeofday () < box_open_time +. 1. then widgets.ok_button#grab_default ();
        component_tree#highlight_problems;

        if widgets.systray_icon#have_icon then (
          if ready then (
            widgets.systray_icon#set_tooltip (Printf.sprintf "Downloading updates for %s" reqs.Requirements.interface_uri);
            widgets.ok_button#set_active true
          ) else (
            (* Should already be reporting an error, but blink it again just in case *)
            widgets.systray_icon#set_blinking None
          )
        );

        (* Wait for user choice or refresh request *)
        widgets.refresh_button#misc#set_sensitive true;
        component_tree#set_update_icons true;
        fst !need_recalculate >>= fun () ->
        refresh_loop ()
      | _ -> Lwt.return () in
    let refresh_thread = refresh_loop () in
    Lwt.on_failure refresh_thread (fun ex -> log_warning ~ex "refresh_thread crashed");

    (* Wait for user to click Cancel or Run *)
    user_response >>= fun response ->
    watcher#abort_all_downloads;
    Lwt.cancel refresh_thread;
    dialog#destroy ();
    match response with
    | `Ok ->
        let (ready, results) = watcher#results in
        assert ready;
        `Success (Zeroinstall.Solver.selections results) |> Lwt.return
    | `Aborted_by_user -> `Aborted_by_user |> Lwt.return
  ) in

  object
    method recalculate = recalculate ~force:false
    method result = Lazy.force result

    (* Return the dialog window. If we're in systray mode, blink the icon and wait for the user
     * to click on it first. *)
    method ensure_main_window =
      widgets.systray_icon#set_blinking (Some "Interaction needed - click to open main window");
      main_window_open >|= fun () -> (dialog :> GWindow.window_skel)

    (* Called at regular intervals while there are downloads in progress, and once at the end.
     * Update the display. *)
    method update_download_status ~n_completed_downloads ~size_completed_downloads downloads =
      if Lwt.state user_response = Lwt.Sleep then (
        (* (dialog is still in use) *)
        component_tree#update_download_status downloads;

        if downloads = [] then (
          widgets.progress_area#misc#hide ();
          Gdk.Window.set_cursor dialog#misc#window (Lazy.force Gtk_utils.default_cursor)
        ) else if not widgets.progress_area#misc#visible then (
          widgets.progress_area#misc#show ();
          Gdk.Window.set_cursor dialog#misc#window (Lazy.force Gtk_utils.busy_cursor)
        );

        (* Calculate stats: completed downloads + downloads in progress *)
        let total_so_far = ref size_completed_downloads in
        let total_expected = ref size_completed_downloads in
        let n_downloads = ref n_completed_downloads in
        let any_known = ref false in

        downloads |> List.iter (fun dl ->
          let (so_far, expected, _finished) = Lwt_react.S.value dl.Downloader.progress in
          total_so_far := Int64.add !total_so_far so_far;
          if expected <> None then any_known := true;
          (* Guess about 4K for feeds/icons *)
          let expected = expected |? lazy (if Int64.compare so_far 4096L > 0 then so_far else 4096L) in
          total_expected := Int64.add !total_expected expected;
          incr n_downloads
        );

        let progress_text = Printf.sprintf "%s / %s" (U.format_size !total_so_far) (U.format_size !total_expected) in
        if !n_downloads = 1 then
          widgets.progress_info#set_text (Printf.sprintf "Downloading one file (%s)" progress_text)
        else
          widgets.progress_info#set_text (Printf.sprintf "Downloading %d files (%s)" !n_downloads progress_text);

        if downloads = [] then (
          widgets.progress_bar#set_fraction 0.0;
        ) else if !total_expected = 0L || (!n_downloads < 2 && not !any_known) then (
          widgets.progress_bar#pulse ()
        ) else (
          widgets.progress_bar#set_fraction (Int64.to_float !total_so_far /. Int64.to_float !total_expected)
        );
      )

    method impl_added_to_store = component_tree#update

    method update =
      let (ready, results) = watcher#results in
      widgets.ok_button#misc#set_sensitive ready;

      let new_roles =
        Zeroinstall.Solver.Output.to_map results
        |> RoleMap.mapi (fun new_role _impl -> new_role) in

      !component_boxes |> RoleMap.iter (fun old_role box ->
        RoleMap.find_opt old_role new_roles |> box#update
      );

      component_tree#update

    method report_error ex = report_error ex
  end
