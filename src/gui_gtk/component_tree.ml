(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The tree of components in the main window. *)

open Support
open Support.Common
open Gtk_common
open Zeroinstall.General
open Zeroinstall

module FeedAttr = Zeroinstall.Constants.FeedAttr
module Feed_url = Zeroinstall.Feed_url
module Impl = Zeroinstall.Impl
module F = Zeroinstall.Feed
module FC = Zeroinstall.Feed_cache
module U = Support.Utils
module Downloader = Zeroinstall.Downloader

let icon_size = 20

let get (model:#GTree.model) row column =
  try Some (model#get ~row ~column)
  with Failure _ -> None

(** Add up the so_far and expected fields of a list of downloads. *)
let rec count_downloads = function
  | [] -> (0L, None)
  | (x::xs) ->
      let so_far, expected, _finished = Lwt_react.S.value x.Downloader.progress in   (* TODO: remove finished? *)
      let so_far_rest, expected_rest = count_downloads xs in
      (* This seems a bit odd, but it's what the Python does. *)
      let expected_total =
        match expected, expected_rest with
        | None, _ -> expected_rest
        | Some _ as extra, None -> extra
        | Some extra, Some rest -> Some (Int64.add extra rest) in
      (Int64.add so_far so_far_rest, expected_total)

let first_para text =
  let first =
    try
      let index = Str.search_forward (Str.regexp_string "\n\n") text 0 in
      String.sub text 0 index
    with Not_found -> text in
  Str.global_replace (Str.regexp_string "\n") " " first |> String.trim

(* Visit all nodes from [start] up to and including [stop]. *)
exception Stop_walk
let walk_tree (model:GTree.tree_store) ~start ~stop fn =
  let rec walk ~start =
    fn start;
    let child_iter =
      try Some (model#iter_children (Some start))
      with Invalid_argument _ -> None in
    child_iter |> if_some (fun start -> walk ~start);
    if Some (model#get_path start) <> stop && model#iter_next start then
      walk ~start
    else
      raise Stop_walk in
  try walk ~start
  with Stop_walk -> ()

module SolverTree = Tree.Make(Solver.Output)

let build_tree_view config ~parent ~packing ~icon_cache ~show_component ~recalculate ~watcher =
  (* Model *)
  let columns = new GTree.column_list in
  let implementation = columns#add Gobject.Data.caml in
  let component_role = columns#add Gobject.Data.caml in
  let interface_name = columns#add Gobject.Data.string in
  let version_col = columns#add Gobject.Data.string in
  let summary_col = columns#add Gobject.Data.string in
  let download_size = columns#add Gobject.Data.string in
  let stability = columns#add Gobject.Data.string in
  let icon = columns#add Gobject.Data.gobject in
  let background = columns#add Gobject.Data.string in
  let problem = columns#add Gobject.Data.boolean in
  let model = GTree.tree_store columns in

  (* View *)
  let view = GTree.view ~model ~packing () in
  let action_arrow = view#misc#render_icon ~size:`SMALL_TOOLBAR `PROPERTIES in

  let icon_renderer = GTree.cell_renderer_pixbuf [] in
  let text_plain = GTree.cell_renderer_text [] in
  let text_coloured = GTree.cell_renderer_text [] in
  let text_ellip = GTree.cell_renderer_text [] in
  let action_renderer = GTree.cell_renderer_pixbuf [`PIXBUF action_arrow] in
  (new GObj.gobject_ops text_ellip#as_renderer)#set_property "ellipsize" (`INT 3); (* PANGO_ELLIPSIZE_END *)

  let add ~title cell column =
    let view_col = GTree.view_column ~title ~renderer:(cell, ["text", column]) () in
    append_column view view_col;
    view_col in

  let component_vc = GTree.view_column ~title:"Component" () in
  append_column view component_vc;
  component_vc#pack ~expand:false icon_renderer;
  component_vc#add_attribute icon_renderer "pixbuf" icon;
  component_vc#pack text_plain;
  component_vc#add_attribute text_plain "text" interface_name;
  let version_vc = add ~title:"Version" text_coloured version_col in
  version_vc#add_attribute text_coloured "background" background;
  let fetch_vc = add ~title:"Fetch" text_plain download_size in
  let summary_vc = add ~title:"Description" text_ellip summary_col in
  summary_vc#misc#set_property "expand" (`BOOL true);
  let action_vc = GTree.view_column ~renderer:(action_renderer, []) () in
  append_column view action_vc;

  view#set_enable_search true;

  (* Tooltips *)
  let get_tooltip row col =
    match get model row component_role with
    | None -> "ERROR"
    | Some role ->
        let iface = role.Solver.iface in
        if col = component_vc#get_oid then (
          Printf.sprintf "Full name: %s" iface
        ) else if col = summary_vc#get_oid then (
          match watcher#feed_provider#get_feed (Feed_url.master_feed_of_iface iface) with
          | Some (main_feed, _overrides) -> F.get_description config.langs main_feed |> default "-" |> first_para
          | None -> "-"
        ) else if col = action_vc#get_oid then (
          "Click here for more options..."
        ) else (
          match get model row stability, get model row implementation, get model row version_col with
          | Some stability_str, Some impl, Some version ->
              if col = version_vc#get_oid then (
                let current = Printf.sprintf "Currently preferred version: %s (%s)" version stability_str in
                let prev_version = watcher#original_selections
                  |> pipe_some (Selections.get_selected {Selections.iface; source = role.Solver.source})
                  |> pipe_some (fun sel -> Element.version_opt sel) in
                match prev_version with
                | Some prev_version when version <> prev_version ->
                    Printf.sprintf "%s\nPreviously preferred version: %s" current prev_version
                | _ -> current
              ) else if col = fetch_vc#get_oid then (
                let (_fetch_str, fetch_tip) = Gui.get_fetch_info config impl in
                fetch_tip
              ) else ""
          | _ -> "No suitable version was found. Double-click here to find out why."
        ) in

  view#misc#set_has_tooltip true;
  view#misc#connect#query_tooltip ==> (fun ~x ~y ~kbd tooltip ->
    let (x, y, _) = GtkTree.TreeView.Tooltip.get_context view#as_tree_view ~x ~y ~kbd in
      match view#get_path_at_pos ~x ~y with
      | None -> false
      | Some (path, col, _x, _y) ->
          let row = model#get_iter path in
          GtkBase.Tooltip.set_text tooltip @@ get_tooltip row col#get_oid;
          GtkTree.TreeView.Tooltip.set_cell view#as_tree_view tooltip ~path ~col:col#as_column ();
          true
  );

  (* Menu *)
  let module B = GdkEvent.Button in
  let show_menu row bev =
    let role = model#get ~row ~column:component_role in
    let iface = role.Solver.iface in
    let have_source = Gui.have_source_for watcher#feed_provider iface in
    let menu = GMenu.menu () in
    let packing = menu#add in

    let show_feeds = GMenu.menu_item ~packing ~label:"Show Feeds" () in
    let show_versions = GMenu.menu_item ~packing ~label:"Show Versions" () in
    show_feeds#connect#activate ==> (fun () -> show_component role ~select_versions_tab:false);
    show_versions#connect#activate ==> (fun () -> show_component role ~select_versions_tab:true);

    let compile_item = GMenu.menu_item ~packing ~label:"Compile" () in

    if have_source then (
      let compile ~autocompile () =
        Gtk_utils.async ~parent (fun () ->
          Gui.compile config watcher#feed_provider iface ~autocompile >|= fun () ->
          recalculate ~force:false
        ) in
      let compile_menu = GMenu.menu () in
      compile_item#set_submenu compile_menu;
      let packing = compile_menu#add in

      (GMenu.menu_item ~packing ~label:"Automatic" ())#connect#activate ==> (compile ~autocompile:true);
      (GMenu.menu_item ~packing ~label:"Manual..." ())#connect#activate ==> (compile ~autocompile:false);
    ) else (
      compile_item#misc#set_sensitive false
    );
    menu#popup ~button:(B.button bev) ~time:(B.time bev) in

  view#event#connect#button_press ==> (fun bev ->
    match view#get_path_at_pos ~x:(B.x bev |> truncate) ~y:(B.y bev |> truncate) with
    | Some (path, col, _x, _y) ->
        let button = B.button bev in
        if GdkEvent.get_type bev = `BUTTON_PRESS then (
          if button = 3 || (button < 4 && col#get_oid = action_vc#get_oid) then (
            let row = model#get_iter path in
            show_menu row bev;
            true
          ) else false
        ) else if GdkEvent.get_type bev = `TWO_BUTTON_PRESS && button = 1 then (
          let row = model#get_iter path in
          let role = model#get ~row ~column:component_role in
          show_component role ~select_versions_tab:true;
          true
        ) else false
    | None -> false
  );

  (* Populating the model *)
  let feed_to_iface = Hashtbl.create 100 in
  let default_summary_str = Hashtbl.create 100 in

  let default_icon = view#misc#render_icon ~size:`SMALL_TOOLBAR `EXECUTE in

  let rec update () =
    let (_ready, new_results) = watcher#results in
    let feed_provider = watcher#feed_provider in

    let rec process_tree parent (role, details) =
      let uri = role.Solver.iface in
      let (name, summary, feed_imports) =
        let master_feed = Feed_url.master_feed_of_iface uri in
        match feed_provider#get_feed master_feed with
        | Some (main_feed, _overrides) ->
            (F.name main_feed,
             default "-" @@ F.get_summary config.langs main_feed,
             (F.imported_feeds main_feed))
        | None ->
            let name =
              match master_feed with
              | `Remote_feed url -> XString.tail url (String.rindex url '/' + 1)
              | `Local_feed path -> path in
            (name, "", []) in

      let user_feeds = (feed_provider#get_iface_config uri).FC.extra_feeds in
      let all_feeds = uri :: (user_feeds @ feed_imports |> List.map (fun {Feed_import.src; _} -> Feed_url.format_url src)) in

      (* This is the set of feeds corresponding to this interface. It's used to correlate downloads with components.
       * Note: "distribution:" feeds give their master feed as their hint, so are not included here. *)
      all_feeds |> List.iter (fun feed_url ->
        Hashtbl.add feed_to_iface feed_url uri
      );

      let row = model#append ?parent () in
      model#set ~row ~column:component_role role;
      model#set ~row ~column:interface_name name;
      model#set ~row ~column:summary_col summary;
      model#set ~row ~column:icon (icon_cache#get ~update ~feed_provider uri |> default default_icon);

      match details with
      | `Selected (sel, children) ->
          let impl = Solver.Output.unwrap sel in
          let {Feed_url.id; feed = from_feed} = Impl.get_id impl in
          let overrides = Feed_metadata.load config from_feed in
          let user_stability = Feed_metadata.stability id overrides in
          let version = impl.Impl.parsed_version |> Version.to_string in
          let stability_str =
            match user_stability with
            | Some s -> String.uppercase_ascii (Stability.to_string s)
            | None -> Impl.get_attr_ex FeedAttr.stability impl in
          let prev_version = watcher#original_selections
            |> pipe_some (Selections.get_selected {Selections.iface = uri; source = role.Solver.source})
            |> pipe_some (fun old_sel ->
              let old_version = Element.version old_sel in
              if old_version = version then None
              else Some old_version
            ) in
          let version_str =
            match prev_version with
            | Some prev_version -> Printf.sprintf "%s (was %s)" version prev_version
            | _ -> version in

          let (fetch_str, _fetch_tip) = Gui.get_fetch_info config impl in
          (* Store the summary string, so that we can recover it after displaying progress messages. *)
          Hashtbl.add default_summary_str uri summary;

          model#set ~row ~column:version_col version_str;
          model#set ~row ~column:download_size fetch_str;
          model#set ~row ~column:stability stability_str;
          model#set ~row ~column:implementation impl;
          List.iter (process_tree (Some row)) children
      | `Problem ->
          model#set ~row ~column:problem true;
          model#set ~row ~column:version_col "(problem)" in

    Hashtbl.clear feed_to_iface;
    Hashtbl.clear default_summary_str;
    model#clear ();
    SolverTree.as_tree new_results |> process_tree model#get_iter_first;
    view#expand_all ();
    icon_cache#set_update_icons false in

  update ();

  object
    method set_update_icons value = icon_cache#set_update_icons value
    method update = update ()

    method highlight_problems =
      (* Called when the solve finishes. Highlight any missing implementations. *)
      model#get_iter_first |> if_some (fun start ->
        walk_tree model ~start ~stop:None (fun iter ->
          if get model iter problem = Some true then
            model#set ~row:iter ~column:background "#f88"
        )
      )

    (* Called at regular intervals while there are downloads in progress,
       and once at the end.
       Update the TreeView with the download progress. *)
    method update_download_status all_downloads =
      (* Downloads are associated with feeds. Create the mapping (iface -> downloads) *)
      let hints = Hashtbl.create 10 in
      all_downloads |> List.iter (fun dl ->
        dl.Downloader.hint |> if_some (fun feed ->
          Hashtbl.find_all feed_to_iface feed |> List.iter (fun iface ->
            Hashtbl.add hints iface dl
          )
        )
      );

      (* Only update currently visible rows *)
      let start, stop =
        match view#get_visible_range () with
        | Some (first_visible_path, last_visible_path) -> (Some (model#get_iter first_visible_path), Some last_visible_path)
        | None -> (model#get_iter_first, None) in

      start |> if_some (fun start ->
        walk_tree model ~start ~stop (fun row ->
          let role = model#get ~row ~column:component_role in
          let iface = role.Solver.iface in

          begin match Hashtbl.find_all hints iface with
          | [] ->
              begin try
                let summary_str = Hashtbl.find default_summary_str iface in
                model#set ~row ~column:summary_col summary_str;
              with Not_found -> () end
          | downloads ->
              let so_far, expected = count_downloads downloads in
              let so_far_str = U.format_size so_far in
              let n_downloads = List.length downloads in
              let summary =
                match expected with
                | Some expected ->
                    let expected_str = U.format_size expected in
                    let percentage = 100. *. (Int64.to_float so_far /. Int64.to_float expected) in
                    if n_downloads = 1 then (
                      Printf.sprintf "(downloading %s/%s [%.2f%%])" so_far_str expected_str percentage
                    ) else (
                      Printf.sprintf "(downloading %s/%s [%.2f%%] in %d downloads)" so_far_str expected_str percentage n_downloads
                    )
                | None ->
                    if n_downloads = 1 then (
                      Printf.sprintf "(downloading %s/unknown)" so_far_str
                    ) else (
                      Printf.sprintf "(downloading %s/unknown in %d downloads)" so_far_str n_downloads
                    )
              in

              model#set ~row ~column:summary_col summary end;
        )
      )
  end
