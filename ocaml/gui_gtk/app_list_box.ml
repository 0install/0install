(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The app browser dialog *)

open Zeroinstall.General
open Zeroinstall
open Support.Common
open Gtk_common

module F = Zeroinstall.Feed
module U = Support.Utils
module FC = Zeroinstall.Feed_cache
module Feed_url = Zeroinstall.Feed_url
module Basedir = Support.Basedir

exception Found

(** Search through the configured XDG datadirs looking for .desktop files created by us. *)
let discover_existing_apps config =
  let basedirs = Support.Basedir.get_default_config config.system in
  let re_exec = Str.regexp "^Exec=0launch \\(-- \\)?\\([^ ]*\\) " in
  let system = config.system in
  let already_installed = ref [] in
  basedirs.Basedir.data |> List.iter (fun data_path ->
    let apps_dir = data_path +/ "applications" in
    if system#file_exists apps_dir then (
      match system#readdir apps_dir with
      | Problem ex -> log_warning ~ex "Failed to scan directory '%s'" apps_dir
      | Success items ->
          items |> Array.iter (fun desktop_file ->
            if U.starts_with desktop_file "zeroinstall-" && U.ends_with desktop_file ".desktop" then (
              let full = apps_dir +/ desktop_file in
              try
                full |> system#with_open_in [Open_rdonly] (fun ch ->
                  while true do
                    let line = input_line ch in
                    if Str.string_match re_exec line 0 then (
                      let uri = Str.matched_group 2 line in
                      let url = Feed_url.master_feed_of_iface uri in
                      let name =
                        try
                          match FC.get_cached_feed config url with
                          | Some feed -> feed.F.name
                          | None -> Filename.basename uri
                        with Safe_exception _ ->
                          Filename.basename uri in
                      already_installed := (name, full, uri) :: !already_installed;
                      raise Found
                    )
                  done
                )
              with
              | End_of_file -> log_info "Failed to find Exec line in %s" full
              | Found -> ()
              | ex -> log_warning ~ex "Failed to load .desktop file %s" full
            )
          )
    )
  );
  !already_installed

let by_name_ignore_case (n1, p1, u1) (n2, p2, u2) =
  let r = String.compare (String.lowercase_ascii n1) (String.lowercase_ascii n2) in
  if r <> 0 then r
  else compare (p1, u1) (p2, u2)

(** Use [xdg-open] to show the help files for this implementation. *)
let show_help config sel =
  let system = config.system in
  let help_dir = Element.doc_dir sel in
  let id = Element.id sel in

  let path =
    if U.starts_with id "package:" then (
      match help_dir with
      | None -> raise_safe "No doc-dir specified for package implementation"
      | Some help_dir ->
          if Filename.is_relative help_dir then
            raise_safe "Package doc-dir must be absolute! (got '%s')" help_dir
          else
            help_dir
    ) else (
      let path = Selections.get_path system config.stores sel |? lazy (raise_safe "BUG: not cached!") in
      match help_dir with
      | Some help_dir -> path +/ help_dir
      | None ->
          match Element.get_command "run" sel with
          | None -> path
          | Some run ->
              match Element.path run with
              | None -> path
              | Some main ->
                  (* Hack for ROX applications. They should be updated to set doc-dir. *)
                  let help_dir = path +/ (Filename.dirname main) +/ "Help" in
                  if U.is_dir system help_dir then help_dir
                  else path
    ) in
  U.xdg_open_dir ~exec:false system path

let get_selections tools ~(gui:Ui.ui_handler) uri =
  let reqs = Requirements.run uri in
  match Driver.quick_solve tools reqs with
  | Some sels -> Lwt.return (`Success sels)
  | None ->
      (* Slow path: program isn't cached yet *)
      gui#run_solver tools `Download_only reqs ~refresh:false

let show_help_for_iface tools ~gui uri : unit Lwt.t =
  get_selections tools ~gui uri >|= function
  | `Aborted_by_user -> ()
  | `Success sels ->
      Selections.(get_selected_ex {iface = uri; source = false} sels)
      |> show_help tools#config

let confirm_deletion ~parent name =
  let box = GWindow.dialog
    ~parent
    ~title:"Confirm"
    () in
  let markup = Printf.sprintf "Remove <b>%s</b> from the applications list?" (Gtk_utils.pango_escape name) in
  GMisc.label ~packing:box#vbox#pack ~xpad:20 ~ypad:20 ~markup () |> ignore_widget;
  box#add_button_stock `CANCEL `CANCEL;
  box#add_button_stock `DELETE `DELETE;
  let result, set_result = Lwt.wait () in
  box#set_default_response `DELETE;
  box#connect#response ==> (fun response ->
    box#destroy ();
    Lwt.wakeup set_result (
      match response with
      | `DELETE -> `Delete
      | `CANCEL | `DELETE_EVENT -> `Cancel
    )
  );
  box#show ();
  result

(** If [feed] <needs-terminal> then find one and add it to the start of args. *)
let maybe_with_terminal system feed args =
  if F.needs_terminal feed then (
    if (system#platform).Platform.os = "MacOSX" then (
      (* This is probably wrong, or at least inefficient (we ignore [args] and invoke 0launch again).
       * But I don't know how to make the escaping right - someone on OS X should check it... *)
      let osascript = U.find_in_path_ex system "osascript" in
      let script = "0launch -- " ^ (Feed_url.format_url feed.F.url) in
      [osascript; "-e"; "tell app \"Terminal\""; "-e"; "activate"; "-e"; "do script \"" ^ script ^ "\""; "-e"; "end tell"]
    ) else (
      let terminal_args =
        ["x-terminal-emulator"; "xterm"; "gnome-terminal"; "rxvt"; "konsole"] |> U.first_match (fun terminal ->
          U.find_in_path system terminal |> pipe_some (fun path ->
            if terminal = "gnome-terminal" then Some [path; "-x"]
            else Some [path; "-e"]
          )
        ) |? lazy (raise_safe "Can't find a suitable terminal emulator") in
      terminal_args @ args
    )
  ) else args

let with_busy_cursor (widget:#GObj.widget) f =
  Gdk.Window.set_cursor widget#misc#window (Lazy.force Gtk_utils.busy_cursor);
  Lwt.finalize f
    (fun () ->
       Gdk.Window.set_cursor widget#misc#window (Lazy.force Gtk_utils.default_cursor);
       Lwt.return ()
    )

let run config dialog tools gui uri =
  Gtk_utils.async ~parent:dialog (fun () ->
      with_busy_cursor dialog (fun () ->
          get_selections tools ~gui uri >>= function
          | `Aborted_by_user -> Lwt.return ()
          | `Success sels ->
            let feed_url = Feed_url.master_feed_of_iface uri in
            let feed = FC.get_cached_feed config feed_url |? lazy (raise_safe "BUG: feed still not cached! %s" uri) in
            let exec args ~env = config.system#spawn_detach ~env (maybe_with_terminal tools#config.system feed args) in
            match Exec.execute_selections config ~exec sels [] with
            | `Ok () -> Lwt_unix.sleep 0.5
            | `Dry_run _ -> assert false
        )
  )

let create config ~gui ~tools ~add_app =
  let finished, set_finished = Lwt.wait () in

  let dialog = GWindow.dialog ~title:"0install Applications" () in

  let swin = GBin.scrolled_window
    ~packing:(dialog#vbox#pack ~expand:true)
    ~hpolicy:`NEVER
    ~vpolicy:`AUTOMATIC
    () in

  (* Model *)
  let cols = new GTree.column_list in
  let uri_col = cols#add Gobject.Data.string in
  let name_col = cols#add Gobject.Data.string in
  let icon_col = cols#add (Gobject.Data.gobject_by_name "GdkPixbuf") in
  let path_col = cols#add Gobject.Data.string in

  let model = GTree.list_store cols in

  (* View *)
  let view = GTree.icon_view
    ~model
    ~packing:swin#add
    () in
  view#set_text_column name_col;
  view#set_pixbuf_column icon_col;

  (* Buttons *)
  dialog#add_button "Show Cache" `SHOW_CACHE;
  let actions = dialog#action_area in
  let cache_button = List.hd actions#children in
  cache_button#misc#set_tooltip_text "Show all 0install software currently stored on this computer \
    (i.e. those programs which can be run without a network connection). \
    This can be useful if you're running out of disk space and need to delete something.";
  dialog#action_area#set_child_secondary cache_button true;

  dialog#add_button_stock `ADD `ADD;
  let add_button = List.hd actions#children in
  add_button#misc#set_tooltip_text "Add a new application. You can also just drag a 0install feed URL from \
    your web-browser to this window.";

  dialog#add_button_stock `CLOSE `CLOSE;

  (* Menu *)
  let menu = GMenu.menu () in

  let menu_iface = ref None in
  let run_item = GMenu.menu_item ~packing:menu#add ~label:"Run" () in
  let help_item = GMenu.menu_item ~packing:menu#add ~label:"Show help" () in
  let edit_item = GMenu.menu_item ~packing:menu#add ~label:"Choose versions" () in
  let delete_item = GMenu.menu_item ~packing:menu#add ~label:"Delete" () in

  run_item#connect#activate ==> (fun () ->
    run config dialog tools gui (!menu_iface |? lazy (raise_safe "BUG: no selected item!"))
  );

  help_item#connect#activate ==> (fun () ->
    let uri = !menu_iface |? lazy (raise_safe "BUG: no selected item!") in
    Gtk_utils.async ~parent:dialog (fun () -> show_help_for_iface tools ~gui uri)
  );

  edit_item#connect#activate ==> (fun () ->
    let uri = !menu_iface |? lazy (raise_safe "BUG: no selected item!") in
    let reqs = Requirements.run uri in
    Gtk_utils.async ~parent:dialog (fun () ->
      gui#run_solver tools `Download_only reqs ~refresh:false >|= ignore
    )
  );

  delete_item#connect#activate ==> (fun () ->
    match view#get_selected_items with
    | [path] ->
        let row = model#get_iter path in
        let name = model#get ~row ~column:name_col in
        let path = model#get ~row ~column:path_col in
        dialog#misc#set_sensitive false;
        Gtk_utils.async ~parent:dialog (fun () ->
          Lwt.finalize
            (fun () ->
              confirm_deletion ~parent:dialog name >|= function
              | `Delete ->
                  log_info "rm %s" path;
                  begin
                    try config.system#unlink path
                    with Unix.Unix_error (Unix.EACCES, _, _) ->
                      raise_safe "Permission denied. You may be able to remove the entry manually with:\n\
                                  sudo rm '%s'" path
                  end;
                  model#remove row |> ignore
              | `Cancel -> ()
            )
            (fun () ->
              dialog#misc#set_sensitive true;
              Lwt.return ()
            )
        )
    | _ -> log_warning "Invalid selection!"
  );

  view#event#connect#button_press ==> (fun bev ->
    let module B = GdkEvent.Button in
    let path : Gtk.tree_path option = view#get_path_at_pos (B.x bev |> truncate) (B.y bev |> truncate) in
    match GdkEvent.get_type bev, B.button bev, path with
    | `TWO_BUTTON_PRESS, 1, Some path ->
        let row = model#get_iter path in
        run config dialog tools gui (model#get ~row ~column:uri_col);
        true
    | `BUTTON_PRESS, 3, Some path ->
        view#select_path path;
        let row = model#get_iter path in
        menu_iface := Some (model#get ~row ~column:uri_col);
        menu#popup ~button:(B.button bev) ~time:(B.time bev);
        true
    | _ ->
        false
  );

  let default_icon = view#misc#render_icon ~size:`DIALOG `EXECUTE in

  (* We're missing gtk_icon_size_lookup, but can get it this way instead... *)
  let width = GdkPixbuf.get_width default_icon in
  let height = GdkPixbuf.get_height default_icon in

  (* Populate model *)
  let populate () =
    model#clear ();
    discover_existing_apps config
    |> List.sort by_name_ignore_case
    |> List.iter (fun (name, path, uri) ->
      let row = model#append () in
      model#set ~row ~column:name_col name;
      model#set ~row ~column:uri_col uri;
      model#set ~row ~column:path_col path;
      let url = Feed_url.master_feed_of_iface uri in

      FC.get_cached_icon_path config url
      |> pipe_some (Gtk_utils.load_png_icon config.system ~width ~height)
      |> default default_icon
      |> model#set ~row ~column:icon_col;
    ) in
  populate ();

  let add_and_repopulate uri =
    Gtk_utils.async ~parent:dialog (fun () ->
      add_app uri >>= fun () ->
      populate ();
      Lwt.return ()
    ) in

  (* Drag-and-drop *)

  Gtk_utils.make_iface_uri_drop_target dialog (fun iface ->
    log_info "URI dropped: %s" iface;
    Gtk_utils.sanity_check_iface iface;
    add_and_repopulate iface;
    true
  );

  dialog#connect#response ==> (function
    | `DELETE_EVENT | `CLOSE -> dialog#destroy (); Lwt.wakeup set_finished ()
    | `SHOW_CACHE -> Gtk_utils.async (fun () -> Cache_explorer_box.open_cache_explorer config)
    | `ADD -> add_and_repopulate ""
  );

  dialog#set_default_size
    ~width:(Gdk.Screen.width () / 3)
    ~height:(Gdk.Screen.height () / 3);

  dialog#show ();

  finished
