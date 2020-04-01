(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The system tray notification icon (used for background updates) *)

open Support.Common
open Gtk_common

class tray_icon systray =
  let clicked, set_clicked = Lwt.wait () in
  object (self)
    val mutable icon = None

    method clicked = clicked

    method have_icon = icon <> None

    method private activate () =
      icon |> if_some (fun i ->
        i#set_visible false;
        icon <- None;
        Lwt.wakeup set_clicked ()
      )

    (* If we currently have a tray icon, set it blinking.
     * If we tried and failed to add an icon, activate immediately.
     * If there is no icon, do nothing. *)
    method set_blinking message =
      icon |> if_some (fun icon ->
        message |> if_some icon#set_tooltip_text;
        (* If the icon isn't embedded yet, give it a chance first... *)
        Gtk_utils.async (fun () ->
          begin if not icon#is_embedded then Lwt_unix.sleep 0.5 else Lwt.return () end >|= fun () ->
          if not icon#is_embedded then (
            log_info "No system-tray support, so opening main window immediately";
            self#activate ()
          )
        )
      )

    method set_tooltip msg = icon |> if_some (fun icon -> icon#set_tooltip_text msg)

    initializer
      if systray then (
        let i = GMisc.status_icon_from_icon_name "zeroinstall" in
        icon <- Some i;
        i#connect#activate ==> self#activate
      ) else (
        Lwt.wakeup set_clicked ()
      )
  end
