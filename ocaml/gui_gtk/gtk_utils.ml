(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Some helper functions for GTK. *)

open Support.Common

module U = Support.Utils

(** Create a widget containing a stock icon and a label. Useful in buttons. *)
let stock_label ~packing ?(use_mnemonic=false) ~stock ~label () =
  let align = GBin.alignment ~packing ~xalign:0.5 ~xscale:0.0 () in
  let hbox = GPack.hbox ~packing:align#add ~spacing:2 ()  in
  GMisc.image ~packing:hbox#pack ~stock ~icon_size:`BUTTON () |> ignore;
  GMisc.label ~packing:hbox#pack ~use_underline:use_mnemonic ~text:label () |> ignore

(** Create a button with a stock icon and a custom label. *)
let mixed_button ~packing ?use_mnemonic ~stock ~label () =
  let button = GButton.button ~packing () in
  stock_label ~packing:button#add ?use_mnemonic ~stock ~label ();
  button

(** We refuse to load anything that isn't a PNG to reduce the attack surface (otherwise,
 * an attacker can try to exploit any of Gdk's many loaders). Lablgtk doesn't let us
 * do this directly, so we approximate by testing the header and hoping Gdk does the same. *)
let load_png_icon (system:system) ~width ~height path : GdkPixbuf.pixbuf option =
  let png_header = "\x89PNG\r\n\x1a\n" in
  try
    let header = path |> system#with_open_in [Open_rdonly; Open_binary] (U.read_upto (String.length png_header)) in
    if header = png_header then (
      Some (GdkPixbuf.from_file_at_size ~width ~height path)
    ) else (
      None
    )
  with ex ->
    log_warning ~ex "Failed to load PNG icon '%s'" path;
    None

(** Run [fn ()] asynchronously. If it throws an exception, report it in an error dialog. *)
let async ?parent fn =
  Lwt.ignore_result (
    try_lwt fn ()
    with ex ->
      log_info ~ex "Unhandled exception from async Lwt thread";
      Alert_box.report_error ?parent ex;
      Lwt.return ()
  )

(* Lazy to let GTK initialise first *)
let default_cursor = lazy (Gdk.Cursor.create `LEFT_PTR)

(* We used to have a nice animated pointer+watch, but it stopped working at some
 * point (even in the Python).
 * See: http://mail.gnome.org/archives/gtk-list/2007-May/msg00100.html *)
let busy_cursor = lazy (Gdk.Cursor.create `WATCH)
