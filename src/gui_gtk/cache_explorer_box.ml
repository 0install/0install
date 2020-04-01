(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** GTK cache explorer dialog (for "0install store manage") *)

open Zeroinstall.General
open Support
open Support.Common
open Gtk_common

module Impl = Zeroinstall.Impl
module F = Zeroinstall.Feed
module U = Support.Utils
module FC = Zeroinstall.Feed_cache
module FeedAttr = Zeroinstall.Constants.FeedAttr
module Feed_url = Zeroinstall.Feed_url
module Manifest = Zeroinstall.Manifest

let rec size_of_item system path =
  match system#lstat path with
  | None -> 0L
  | Some info ->
      match info.Unix.st_kind with
      | Unix.S_REG | Unix.S_LNK -> Int64.of_int info.Unix.st_size
      | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> log_warning "Bad file kind for %s" path; 0L
      | Unix.S_DIR ->
          match system#readdir path with
          | Ok items -> items |> Array.fold_left (fun acc item -> Int64.add acc (size_of_item system (path +/ item))) 0L
          | Error ex -> log_warning ~ex "Can't scan %s" path; 0L

(** Get the size for an implementation. Get the size from the .manifest if possible. *)
let size_of_impl (system:system) path : Int64.t =
  let man = path +/ ".manifest" in
  match system#lstat man with
  | None -> size_of_item system path
  | Some info ->
      let size = ref @@ Int64.of_int info.Unix.st_size in    (* (include the size of the .manifest file itself) *)
      man |> system#with_open_in [Open_rdonly; Open_binary] (fun stream ->
        try
          while true do
            let line = input_line stream in
            match line.[0] with
            | 'X' | 'F' ->
                begin match Str.bounded_split_delim XString.re_space line 5 with
                | [_type; _hash; _mtime; item_size; _name] -> size := Int64.add !size (Int64.of_string item_size)
                | _ -> () end
            | _ -> ()
          done
        with End_of_file -> ()
      );
      !size

let cache_help = Help_box.create "Cache Explorer Help" [
("Overview",
"When you run a program using 0install, it downloads a suitable implementation (version) of the program and of \
each library it uses. Each of these is stored in the cache, each in its own directory.\n\
\n\
0install lets you have many different versions of each program on your computer at once. This is useful, \
since it lets you use an old version if needed, and different programs may need to use \
different versions of a single library in some cases.\n\
\n\
The cache viewer shows you all the implementations in your cache. \
This is useful to find versions you don't need anymore, so that you can delete them and \
free up some disk space.");

("Operations",
"When you select one or more implementations, the details are shown in the box at the bottom, with some buttons \
along the side:\n\
Delete will delete the directory.\n\
Verify will check that the contents of the directory haven't been modified.\n\
Open will open the directory in your file manager.");

("Unowned implementations",
"The cache viewer searches through all your feeds (XML files) to find out which implementations \
they use. The 'Name' and 'Version' columns show what the implementation is used for. \
If no feed can be found for an implementation, it is shown as '(unowned)'.\n\
\n\
Unowned implementations can result from old versions of a program no longer being listed \
in the feed file or from sharing the cache with other users.");

("Temporary files",
"Temporary directories (listed as '(temporary)') are created when unpacking an implementation after \
downloading it. If the archive is corrupted, the unpacked files may be left there. Unless \
you are currently unpacking new programs, it should be fine to delete all of these (hint: click on the 'Name' \
column title to sort by name, then select all of them using Shift-click.");
]

let show_verification_box config ~parent paths =
  let box = GWindow.message_dialog
    ~parent
    ~buttons:GWindow.Buttons.close
    ~message_type:`INFO
    ~resizable:true
    ~title:"Verify"
    ~message:"Verifying..."
    () in
  box#set_use_markup true;
  box#show ();

  let swin = GBin.scrolled_window
    ~packing:(box#vbox#pack ~expand:true)
    ~hpolicy:`AUTOMATIC
    ~vpolicy:`AUTOMATIC
    ~show:false
    () in

  let report_text = GText.view ~packing:swin#add () in
  report_text#misc#modify_font (GPango.font_description_from_string "mono");
  let n_good = ref 0 in
  let n_bad = ref 0 in

  let report_problem msg =
    swin#misc#show ();
    report_text#buffer#insert msg in

  let cancelled = ref false in
  box#connect#response ==> (fun _ ->
    cancelled := true;
    box#destroy ()
  );

  let n_items = List.length paths in
  let n = ref 0 in

  Gdk.Window.set_cursor box#misc#window (Lazy.force Gtk_utils.busy_cursor);
  Gtk_utils.async ~parent:box (fun () ->
      let rec loop = function
        | _ when !cancelled -> Lwt.return `Cancelled
        | [] -> Lwt.return `Done
        | x::xs ->
          Lwt.catch
            (fun () ->
               incr n;
               box#set_text (Printf.sprintf "Checking item %d of %d" !n n_items);
               let digest = Manifest.parse_digest (Filename.basename x) in
               Lwt_preemptive.detach (Manifest.verify config.system ~digest) x >|= fun () ->
               incr n_good
            )
            (function 
              | Safe_exn.T e ->
                let space = if !n_bad = 0 then "" else "\n\n" in
                incr n_bad;
                report_problem @@ Format.asprintf "%s%s:@.%a@." space x Safe_exn.pp e;
                Lwt.return ()
              | ex -> Lwt.fail ex
            )
          >>= fun () ->
          loop xs in
      loop paths >>= function
      | `Done ->
        Gdk.Window.set_cursor box#misc#window (Lazy.force Gtk_utils.default_cursor);
        if !n_bad = 1 && !n_good = 0 then
          box#set_text "<b>Verification failed!</b>"
        else if !n_bad > 0 then
          box#set_text (Printf.sprintf "<b>Verification failed</b>\nFound bad items (%d / %d)" !n_bad (!n_bad + !n_good))
        else if !n_good = 1 then
          box#set_text "Verification successful!"
        else
          box#set_text (Printf.sprintf "Verification successful (%d items)" !n_good);
        Lwt.return ()
      | `Cancelled ->
        Lwt.return ()
  )

let confirm_deletion ~parent n_items =
  let message =
    if n_items = 1 then "Delete this item?"
    else Printf.sprintf "Delete these %d selected items?" n_items in
  let box = GWindow.dialog
    ~parent
    ~title:"Confirm"
    () in
  GMisc.label ~packing:box#vbox#pack ~xpad:20 ~ypad:20 ~text:message () |> ignore_widget;
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

let open_cache_explorer config =
  let finished, set_finished = Lwt.wait () in

  let dialog = GWindow.dialog ~title:"0install Cache Explorer" () in
  dialog#misc#set_sensitive false;

  let swin = GBin.scrolled_window
    ~packing:(dialog#vbox#pack ~expand:true)
    ~hpolicy:`AUTOMATIC
    ~vpolicy:`AUTOMATIC
    () in

  (* Model *)
  let cols = new GTree.column_list in
  let owner_col = cols#add Gobject.Data.string in
  let impl_dir_col = cols#add Gobject.Data.string in
  let version_str_col = cols#add Gobject.Data.string in
  let size_col = cols#add Gobject.Data.int64 in
  let size_str_col = cols#add Gobject.Data.string in

  let model = Unsorted_list.list_store cols in
  let sorted_model = Unsorted_list.model_sort model in

  (* View *)
  let view = GTree.view
    ~model:sorted_model
    ~packing:swin#add
    ~enable_search:true
    ~search_column:owner_col.GTree.index
    ~headers_clickable:true
    () in
  let renderer = GTree.cell_renderer_text [] in
  let owner_vc = GTree.view_column ~title:"Name" ~renderer:(renderer, ["text", owner_col]) () in
  let version_vc = GTree.view_column ~title:"Version" ~renderer:(renderer, ["text", version_str_col]) () in
  let size_vc = GTree.view_column ~title:"Size" ~renderer:(renderer, ["text", size_str_col]) () in

  owner_vc#set_sort_column_id owner_col.GTree.index;
  size_vc#set_sort_column_id size_col.GTree.index;

  append_column view owner_vc;
  append_column view version_vc;
  append_column view size_vc;

  let selection = view#selection in

  (* Details area *)
  let details_frame = GBin.frame
    ~packing:dialog#vbox#pack
    ~border_width:5
    ~shadow_type:`OUT () in

  let table = GPack.table
    ~packing:details_frame#add
    ~columns:3 ~rows:2
    ~col_spacings:4
    ~border_width:4
    ~homogeneous:false
    () in

  GMisc.label ~packing:(table#attach ~top:0 ~left:0) ~text:"Feed:" ~xalign:1.0 () |> ignore_widget;
  GMisc.label ~packing:(table#attach ~top:1 ~left:0) ~text:"Path:" ~xalign:1.0 () |> ignore_widget;
  GMisc.label ~packing:(table#attach ~top:2 ~left:0) ~text:"Details:" ~xalign:1.0 () |> ignore_widget;

  let details_iface = GMisc.label ~packing:(table#attach ~top:0 ~left:1 ~expand:`X) ~xalign:0.0 ~selectable:true () in
  let details_path = GMisc.label ~packing:(table#attach ~top:1 ~left:1 ~expand:`X) ~xalign:0.0 ~selectable:true () in
  let details_extra = GMisc.label ~packing:(table#attach ~top:2 ~left:1 ~expand:`X) ~xalign:0.0 ~selectable:true () in
  details_iface#set_ellipsize `MIDDLE;
  details_path#set_ellipsize `MIDDLE;
  details_extra#set_ellipsize `END;

  let delete = GButton.button ~packing:(table#attach ~top:0 ~left:2) ~stock:`DELETE () in
  delete#connect#clicked ==> (fun () ->
    let iters = selection#get_selected_rows |> List.map (fun sorted_path ->
      sorted_model#get_iter sorted_path |> Unsorted_list.convert_iter_to_child_iter sorted_model
    ) in
    dialog#misc#set_sensitive false;
    Gdk.Window.set_cursor dialog#misc#window (Lazy.force Gtk_utils.busy_cursor);
    Gtk_utils.async ~parent:dialog (fun () ->
      Lwt.finalize
        (fun () ->
           let rec loop = function
             | [] -> Lwt.return ()
             | x::xs ->
               let dir = Unsorted_list.get model ~row:x ~column:impl_dir_col in
               Lwt_preemptive.detach (U.rmtree ~even_if_locked:true config.system) dir >>= fun () ->
               Unsorted_list.remove model x |> ignore;
               loop xs in
           confirm_deletion ~parent:dialog (List.length iters) >>= function
           | `Delete -> loop iters
           | `Cancel -> Lwt.return ()
        )
        (fun () ->
           Gdk.Window.set_cursor dialog#misc#window (Lazy.force Gtk_utils.default_cursor);
           dialog#misc#set_sensitive true;
           Lwt.return ()
        )
    )
  );

  let verify = Gtk_utils.mixed_button ~packing:(table#attach ~top:1 ~left:2) ~stock:`FIND ~label:"Verify" () in
  verify#connect#clicked ==> (fun () ->
    let dirs = selection#get_selected_rows |> List.map (fun path ->
      let row = sorted_model#get_iter path in
      sorted_model#get ~row ~column:impl_dir_col
    ) in
    show_verification_box config ~parent:dialog dirs
  );

  let open_button = GButton.button ~packing:(table#attach ~top:2 ~left:2) ~stock:`OPEN () in
  open_button#connect#clicked ==> (fun () ->
    match selection#get_selected_rows with
    | [path] ->
        let row = sorted_model#get_iter path in
        let dir = sorted_model#get ~row ~column:impl_dir_col in
        U.xdg_open_dir ~exec:false config.system dir
    | _ -> log_warning "Invalid selection!"
  );

  details_frame#misc#set_sensitive false;

  (* Buttons *)
  dialog#add_button_stock `HELP `HELP;
  (* Lablgtk uses the wrong response code for HELP, so we have to do this manually. *)
  let actions = dialog#action_area in
  actions#set_child_secondary (List.hd actions#children) true;

  dialog#add_button_stock `CLOSE `CLOSE;

  dialog#connect#response ==> (function
    | `DELETE_EVENT | `CLOSE -> dialog#destroy (); Lwt.wakeup set_finished ()
    | `HELP -> cache_help#display
  );

  dialog#set_default_size
    ~width:(Gdk.Screen.width () / 3)
    ~height:(Gdk.Screen.height () / 3);

  dialog#show ();

  (* Make sure the GUI appears before we start the (slow) scan *)
  Gdk.Window.set_cursor dialog#misc#window (Lazy.force Gtk_utils.busy_cursor);
  Gdk.X.flush ();

  (* Populate model *)
  let all_digests = Zeroinstall.Stores.get_available_digests config.system config.stores in
  let ok_feeds = ref [] in

  (* Look through cached feeds for implementation owners *)
  let all_feed_urls = FC.list_all_feeds config in
  all_feed_urls |> XString.Set.iter (fun url ->
    try
      match FC.get_cached_feed config (`Remote_feed url) with
      | Some feed -> ok_feeds := feed :: !ok_feeds
      | None -> log_warning "Feed listed but now missing! %s" url
    with ex ->
      log_info ~ex "Error loading feed %s" url;
  );

  (* Map each digest to its implementation *)
  let impl_of_digest = Hashtbl.create 1024 in
  !ok_feeds |> List.iter (fun feed ->
    (* For each implementation... *)
    F.zi_implementations feed |> XString.Map.iter (fun _id impl ->
      match impl.Impl.impl_type with
      | `Cache_impl info ->
          (* For each digest... *)
          info.Impl.digests |> List.iter (fun parsed_digest ->
            let digest = Manifest.format_digest parsed_digest in
            if Hashtbl.mem all_digests digest then (
              Hashtbl.add impl_of_digest digest (feed, impl)
            )
          )
      | `Local_impl _ -> assert false
    );
  );

  (* Add each cached implementation to the model *)
  all_digests |> Hashtbl.iter (fun digest dir ->
    let row = Unsorted_list.append model in
    Unsorted_list.set model ~row ~column:impl_dir_col @@ dir +/ digest;
    try
      let feed, impl = Hashtbl.find impl_of_digest digest in
      Unsorted_list.set model ~row ~column:owner_col @@ F.name feed;
      Unsorted_list.set model ~row ~column:version_str_col @@ Impl.get_attr_ex FeedAttr.version impl;
    with Not_found ->
      try
        Manifest.parse_digest digest |> ignore;
        Unsorted_list.set model ~row ~column:owner_col "(unowned)";
      with _ ->
        Unsorted_list.set model ~row ~column:owner_col "(temporary)";
  );

  (* Now go back and fill in the sizes *)
  begin match Unsorted_list.get_iter_first model with
    | Some row ->
      let rec loop () =
        let dir = Unsorted_list.get model ~row ~column:impl_dir_col in
        Lwt_preemptive.detach (size_of_impl config.system) dir >>= fun size ->
        Unsorted_list.set model ~row ~column:size_col size;
        Unsorted_list.set model ~row ~column:size_str_col (U.format_size size);
        if Unsorted_list.iter_next model row then loop ()
        else Lwt.return () in
      loop ()
    | None -> Lwt.return ()
  end >>= fun () ->

  (* Sort by size initially *)
  sorted_model#set_sort_column_id size_col.GTree.index `DESCENDING;
  Gdk.Window.set_cursor dialog#misc#window (Lazy.force Gtk_utils.default_cursor);

  (* Update the details panel when the selection changes *)
  selection#set_mode `MULTIPLE;
  selection#connect#changed ==> (fun () ->
    let interface, path, extra, sensitive, single =
      match selection#get_selected_rows with
      | [] -> ("", "", [], false, false)
      | [path] ->
          let row = sorted_model#get_iter path in
          let dir = sorted_model#get ~row ~column:impl_dir_col in
          let digest = Filename.basename dir in
          begin try
            let feed, impl = Hashtbl.find impl_of_digest digest in
            let extra = [
              "arch:" ^ Zeroinstall.Arch.format_arch (impl.Impl.os, impl.Impl.machine);
              "langs:" ^ (Impl.get_langs impl |> List.map Support.Locale.format_lang |> String.concat ",");
            ] in
            (Feed_url.format_url (F.url feed), dir, extra, true, true)
          with Not_found ->
            let extra =
              match config.system#readdir dir with
              | Error ex -> ["error:" ^ Printexc.to_string ex]
              | Ok items -> ["files:" ^ (Array.to_list items |> String.concat ",")] in
            ("-", dir, extra, true, true) end
      | paths ->
          (Printf.sprintf "(%d selected items)" (List.length paths), "", [], true, false) in
    details_iface#set_text interface;
    details_path#set_text path;
    details_extra#set_text (String.concat ", " extra);
    details_frame#misc#set_sensitive sensitive;
    open_button#misc#set_sensitive single;
  );


  dialog#misc#set_sensitive true;

  finished
