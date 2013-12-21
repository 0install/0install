(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The dialog for adding a new app (used by "0desktop") *)

open Support.Common
open Zeroinstall.General

module F = Zeroinstall.Feed
module U = Support.Utils
module FC = Zeroinstall.Feed_cache
module Feed_url = Zeroinstall.Feed_url

(** Write a .desktop file for this application. *)
let xdg_add_to_menu config feed =
  let system = config.system in
  U.finally_do
    (U.rmtree system ~even_if_locked:true)
    (U.make_tmp_dir system ~prefix:"0desktop-" Filename.temp_dir_name)
    (fun tmpdir ->
      let name = feed.F.name |> String.lowercase |> Str.global_replace U.re_dir_sep "-" |> Str.global_replace U.re_space "" in
      let desktop_name = tmpdir +/ ("zeroinstall-" ^ name ^ ".desktop") in
      let icon_path = FC.get_cached_icon_path config feed.F.url in
      desktop_name |> system#with_open_out [Open_wronly; Open_creat] ~mode:0o600 (fun ch ->
        Printf.fprintf ch
          "[Desktop Entry]\n\
          # This file was generated by 0install.\n\
          # See the Zero Install project for details: http://0install.net\n\
          Type=Application\n\
          Version=1.0\n\
          Name=%s\n\
          Comment=%s\n\
          Exec=0launch -- %s %%f\n\
          Categories=Application;%s\n"
          feed.F.name
          (F.get_summary config.langs feed |> default "")
          (Feed_url.format_url feed.F.url)
          (F.get_category feed |> default "");

        icon_path |> if_some (Printf.fprintf ch "Icon=%s\n");
        if F.needs_terminal feed then output_string ch "Terminal=true\n";
      );
      system#create_process ["xdg-desktop-menu"; "install"; desktop_name] Unix.stdin Unix.stdout Unix.stderr
      |> Support.System.reap_child;
    )

let create ~(gui:Zeroinstall.Ui.ui_handler) ~tools initial_uri =
  let config = tools#config in
  let finished, set_finished = Lwt.wait () in

  let dialog = GWindow.dialog ~title:"Add New Application" () in
  (* Missing from lablgtk: dialog#set_keep_above true; *)

  let frame = GBin.frame ~packing:(dialog#vbox#pack ~expand:true) ~shadow_type:`NONE ~border_width:8 () in
  let title = GMisc.label ~markup:"<b>Application to install</b>" () in
  frame#set_label_widget (Some (title :> GObj.widget));
  let vbox = GPack.vbox ~packing:frame#add ~border_width:12 ~spacing:12 () in
  GMisc.label
    ~packing:vbox#pack
    ~xalign:0.0
    ~line_wrap:true
    ~markup:"<i>Enter the URI of the application you want to install, \
             or drag its link from a web-browser into this window.</i>" () |> ignore;

  let hbox = GPack.hbox ~packing:vbox#pack ~spacing:4 () in
  GMisc.label ~packing:hbox#pack ~text:"URI:" () |> ignore;
  let entry = GEdit.entry ~packing:(hbox#pack ~expand:true) ~activates_default:true ~text:initial_uri () in

  (* Buttons *)
  dialog#add_button_stock `CANCEL `CANCEL;
  dialog#add_button_stock `ADD `ADD;
  dialog#set_default_response `ADD;

  let set_uri_ok () =
    dialog#set_response_sensitive `ADD (entry#text <> "") in
  entry#connect#changed ~callback:set_uri_ok |> ignore;
  set_uri_ok ();

  let add () =
    let iface = entry#text in
    Gtk_utils.sanity_check_iface iface;
    dialog#misc#set_sensitive false;
    try_lwt
      let reqs = Zeroinstall.Requirements.default_requirements iface in
      match_lwt gui#run_solver tools `Download_only reqs ~refresh:false with
      | `Aborted_by_user -> Lwt.return ()
      | `Success _ ->
          let feed_url = Feed_url.master_feed_of_iface iface in
          let feed = Zeroinstall.Feed_cache.get_cached_feed config feed_url |? lazy (raise_safe "BUG: feed still not cached!") in
          xdg_add_to_menu config feed;
          dialog#destroy ();
          Lwt.wakeup set_finished ();
          Lwt.return ()
    finally
      dialog#misc#set_sensitive true;
      Lwt.return () in

  (* Drag-and-drop *)

  Gtk_utils.make_iface_uri_drop_target dialog (fun iface ->
    log_info "URI dropped: %s" iface;
    entry#set_text iface;
    Gtk_utils.async ~parent:dialog add;
    true
  ) |> ignore;

  dialog#connect#response ~callback:(function
    | `DELETE_EVENT | `CANCEL -> dialog#destroy (); Lwt.wakeup set_finished ()
    | `ADD -> Gtk_utils.async ~parent:dialog add;
  ) |> ignore;
  dialog#show ();


  finished
