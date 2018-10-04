(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Some helper functions for GTK. *)

open Support
open Support.Common
open Gtk_common

module U = Support.Utils

(** Create a widget containing a stock icon and a label. Useful in buttons. *)
let stock_label ~packing ?(use_mnemonic=false) ~stock ~label () =
  let align = GBin.alignment ~packing ~xalign:0.5 ~xscale:0.0 () in
  let hbox = GPack.hbox ~packing:align#add ~spacing:2 ()  in
  GMisc.image ~packing:hbox#pack ~stock ~icon_size:`BUTTON () |> ignore_widget;
  GMisc.label ~packing:hbox#pack ~use_underline:use_mnemonic ~text:label () |> ignore_widget

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
    Lwt.catch fn
      (fun ex ->
        log_info ~ex "Unhandled exception from async Lwt thread";
        Alert_box.report_error ?parent ex;
        Lwt.return ()
      )
  )

(* Lazy to let GTK initialise first *)
let default_cursor = lazy (Gdk.Cursor.create `LEFT_PTR)

(* We used to have a nice animated pointer+watch, but it stopped working at some
 * point (even in the Python).
 * See: http://mail.gnome.org/archives/gtk-list/2007-May/msg00100.html *)
let busy_cursor = lazy (Gdk.Cursor.create `WATCH)

let pango_escape s =
  s |> Str.global_substitute (Str.regexp "[&<]") (fun s ->
    match Str.matched_string s with
    | "&" -> "&amp;"
    | "<" -> "&lt;"
    | _ -> assert false
  )

(** When a URI is dropped on 'window', call on_success(uri).
    If it returns True, accept the drop. *)
let make_iface_uri_drop_target (window:#GWindow.window_skel) on_success =
  let drag_ops = window#drag in
  drag_ops#dest_set
    ~flags:[`MOTION; `DROP; `HIGHLIGHT]
    ~actions:[`COPY]
    [ Gtk.({ target = "text/uri-list"; flags = []; info = 0 }) ];
  drag_ops#connect#data_received ==> (fun drag_context ~x:_ ~y:_ data ~info:_ ~time ->
    try
      let data = data#data in
      match Str.split (Str.regexp "[\n\r]+") data with
      | [] -> log_warning "Empty list of URIs dropped!"
      | [uri] ->
          if on_success uri then
            drag_context#finish ~success:true ~del:false ~time
      | uris -> log_warning "Multiple URIs dropped: %s" (String.concat "," uris)
    with ex ->
      Alert_box.report_error ~parent:window ex
  )

let sanity_check_iface uri =
  if XString.ends_with uri ".tar.bz2" ||
     XString.ends_with uri ".tar.gz" ||
     XString.ends_with uri ".exe" ||
     XString.ends_with uri ".rpm" ||
     XString.ends_with uri ".deb" ||
     XString.ends_with uri ".tgz" then (
   Safe_exn.failf "This URI (%s) looks like an archive, not a 0install feed. Make sure you're using the feed link!" uri
  )

let combo ~(table:GPack.table) ~top ~label ~choices ~to_string ~value ~callback ~tooltip =
  let data_conv = Gobject.({
    kind = `STRING;
    proj = (fun _ -> failwith "data_conv.proj called!");
    inj = (fun x -> `STRING (Some (to_string x)));
  }) in

  let model, column = GTree.store_of_list data_conv choices in
  GMisc.label ~packing:(table#attach ~left:0 ~top) ~text:label ~xalign:1.0 () |> ignore_widget;
  let combo = GEdit.combo_box ~packing:(table#attach ~left:1 ~top ~expand:`X) ~model () in
  let cell = GTree.cell_renderer_text [] in
  combo#pack ~expand:true cell;
  combo#add_attribute cell "text" column;
  let rec index i = function
    | [] -> log_warning "Current value is not a valid choice!"; 0
    | x :: _ when x = value -> i
    | _ :: rest -> index (i + 1) rest in
  combo#set_active (index 0 choices);
  combo#connect#changed ==> (fun () -> List.nth choices combo#active |> callback);
  combo#misc#set_tooltip_text tooltip
