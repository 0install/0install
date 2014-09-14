(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The per-component dialog (the one with the Feeds and Versions tabs). *)

open Support.Common
open Gtk_common
open Zeroinstall.General
open Zeroinstall

module FeedAttr = Zeroinstall.Constants.FeedAttr
module Impl = Zeroinstall.Impl
module F = Zeroinstall.Feed
module FC = Zeroinstall.Feed_cache
module U = Support.Utils
module Q = Support.Qdom

let format_para para =
  para |> Str.split (Str.regexp_string "\n") |> List.map trim |> String.concat " "

let get_sigs config url =
  match FC.get_cached_feed_path config url with
  | None -> Lwt.return []
  | Some cache_path ->
      if config.system#file_exists cache_path then (
        let xml = U.read_file config.system cache_path in
        lwt sigs, warnings = Support.Gpg.verify config.system xml in
        if warnings <> "" then log_info "get_last_modified: %s" warnings;
        Lwt.return sigs
      ) else Lwt.return []

type feed_description = {
  times : (string * float) list;
  description : string list;
  homepages : string list;
  signatures : Support.Gpg.signature list;
}

let spf = Printf.sprintf

let add_description_text config ~trust_db ~heading_style ~link_style (buffer:GText.buffer) feed description =
  let iter = buffer#start_iter in
  buffer#insert ~iter ~tags:[heading_style] feed.F.name;
  buffer#insert ~iter (spf " (%s)" (default "-" @@ F.get_summary config.langs feed));
  buffer#insert ~iter (spf "\n%s\n" (Feed_url.format_url feed.F.url));

  if description.times <> [] then (
    buffer#insert ~iter "\n";
    description.times |> List.iter (fun (label, time) ->
      buffer#insert ~iter @@ spf "%s: %s\n" label (U.format_time @@ Unix.localtime time)
    )
  );

  if description.description <> [] then (
    buffer#insert ~iter ~tags:[heading_style] "\nDescription";

    description.description |> List.iter (fun para ->
      buffer#insert ~iter "\n";
      buffer#insert ~iter para;
      buffer#insert ~iter "\n";
    )
  );

  if description.homepages <> [] then (
    buffer#insert ~iter "\n";
    description.homepages |> List.iter (fun url ->
      buffer#insert ~iter "Homepage: ";
      buffer#insert ~iter ~tags:[link_style] url;
      buffer#insert ~iter "\n";
    )
  );

  match feed.F.url, description.signatures with
  | `local_feed _, _ -> Lwt.return ()
  | `remote_feed _, [] ->
      buffer#insert ~iter "No signature information (old style feed or out-of-date cache)\n";
      Lwt.return ()
  | `remote_feed _ as feed_url, sigs ->
      let module G = Support.Gpg in
      buffer#insert ~iter ~tags:[heading_style] "\nSignatures\n";
      let domain = Trust.domain_from_url feed_url in
      sigs |> Lwt_list.iter_s (function
        | G.ValidSig {G.fingerprint; G.timestamp} ->
            lwt name = G.get_key_name config.system fingerprint in
            buffer#insert ~iter @@ spf "Valid signature by '%s'\n- Dated: %s\n- Fingerprint: %s\n"
                    (default "<unknown>" name) (U.format_time @@ Unix.localtime timestamp) fingerprint;
            if not (trust_db#is_trusted ~domain fingerprint) then (
              buffer#insert ~iter
                "WARNING: This key is not in the trusted list (either you removed it, or you trust one of the other signatures)\n"
            );
            Lwt.return ()
        | other_sig -> buffer#insert ~iter @@ spf "%s\n" (G.string_of_sig other_sig); Lwt.return ()
      )

(** The formatted text for the details panel. *)
let generate_feed_description config trust_db feed overrides =
  let times = ref [] in
  lwt signatures =
    match feed.F.url with
    | `local_feed _ -> Lwt.return []
    | `remote_feed _ as feed_url ->
        lwt sigs = get_sigs config feed_url in
        if sigs <> [] then (
          let domain = Trust.domain_from_url feed_url in
          match trust_db#oldest_trusted_sig domain sigs with
          | Some last_modified -> times := ("Last upstream change", last_modified) :: !times
          | None -> ()
        );

        overrides.F.last_checked |> if_some (fun last_checked ->
          times := ("Last checked", last_checked) :: !times
        );

        FC.get_last_check_attempt config feed_url |> if_some (fun last_check_attempt ->
          match overrides.F.last_checked with
          | Some last_checked when last_check_attempt <= last_checked ->
              () (* Don't bother reporting successful attempts *)
          | _ ->
              times := ("Last check attempt (failed or in progress)", last_check_attempt) :: !times
        );

        Lwt.return sigs in

  let description =
    match F.get_description config.langs feed with
    | Some description -> Str.split (Str.regexp_string "\n\n") description |> List.map format_para
    | None -> ["-"] in

  let homepages = Element.feed_metadata feed.F.root |> U.filter_map (function
    | `homepage homepage -> Some (Element.simple_content homepage)
    | _ -> None
  ) in

  Lwt.return {
    times = List.rev !times;
    description;
    homepages;
    signatures;
  }

let component_help = Help_box.create "Component Properties Help" [
("Component properties",
"This window displays information about a component of a program. There are two tabs at the top: \
Feeds shows the places where 0install looks for implementations of the component, while \
Versions shows the list of implementations found (from all feeds) in order of preference.");

("The Feeds tab",
"At the top is a list of feeds. By default, 0install uses the full name of the component's interface \
as the default feed location (so if you ask it to run the program \"http://foo/bar.xml\" then it will \
by default get the list of versions by downloading \"http://foo/bar.xml\".\
\n\n\
You can add and remove feeds using the buttons on the right. The main feed may also add \
some extra feeds itself. If you've checked out a developer version of a program, you can use \
the 'Add Local Feed...' button to let 0install know about it, for example.\
\n\n\
Below the list of feeds is a box describing the selected one:\
\n\n\
- At the top is its short name.
- Below that is the address (a URL or filename).
- 'Last upstream change' shows the version of the cached copy of the feed file.
- 'Last checked' is the last time a fresh copy of the upstream feed file was downloaded.
- Then there is a longer description of the feed.");

("The Versions tab",
"This tab shows a list of all known implementations of the interface, from all the feeds. \
The columns have the following meanings:
\n\
Version gives the version number. High-numbered versions are considered to be \
better than low-numbered ones.
\n\
Released gives the date this entry was added to the feed.
\n\
Stability is 'stable' if the implementation is believed to be stable, 'buggy' if \
it is known to contain serious bugs, and 'testing' if its stability is not yet \
known. This information is normally supplied and updated by the author of the \
software, but you can override their rating by right-clicking here (overridden \
values are shown in upper-case). You can also use the special level 'preferred', which \
is ranked higher than anything else.
\n\
Fetch indicates how much data needs to be downloaded to get this version if you don't \
have it. If the implementation has already been downloaded to your computer, \
it will say (cached). (local) means that you installed this version manually and \
told 0install about it by adding a feed. (package) means that this version \
is provided by your distribution's package manager, not by 0install. \
In off-line mode, only locally-available implementations are considered for use.
\n\
Arch indicates what kind of computer system the implementation is for, or 'any' \
if it works with all types of system.
\n\
If you want to know why a particular version wasn't chosen, right-click over it \
and choose \"Explain this decision\" from the popup menu.");

("Sort order",
"The implementations are ordered by version number (highest first), with the \
currently selected one in bold. This is the \"best\" usable version.
\n\
Unusable ones are those for incompatible \
architectures, those marked as 'buggy' or 'insecure', versions explicitly marked as incompatible with \
another component you are using and, in off-line mode, uncached implementations. Unusable \
implementations are shown crossed out.
\n\
For the usable implementations, the order is as follows:
\n\
- Preferred implementations come first.
\n\
- Then, if network use is set to 'Minimal', cached implementations come before \
non-cached.
\n\
- Then, implementations at or above the selected stability level come before all others.
\n\
- Then, higher-numbered versions come before low-numbered ones.
\n\
- Then cached come before non-cached (for 'Full' network use mode).");

("Compiling",
"If there is no binary available for your system then you may be able to compile one from \
source by clicking on the Compile button. If no source is available, the Compile button will \
be shown shaded.")
]

let add_remote_feed ~parent ~watcher ~recalculate tools iface () =
  let box = GWindow.message_dialog
    ~parent
    ~message_type:`QUESTION
    ~buttons:GWindow.Buttons.ok_cancel
    ~title:"Add Remote Feed"
    ~message:"Enter the URL of the new source of implementations of this interface:"
    () in

  let vbox = GPack.vbox ~packing:(box#vbox#pack ~expand:true ~fill:true) ~border_width:4 () in
  let entry = GEdit.entry ~packing:vbox#pack ~activates_default:true () in
  let error_label = GMisc.label ~packing:vbox#pack ~xpad:4 ~ypad:4 ~line_wrap:true ~show:false () in
  box#set_default_response `OK;

  box#connect#response ==> (function
    | `DELETE_EVENT | `CANCEL -> box#destroy ()
    | `OK ->
        error_label#misc#hide ();
        box#misc#set_sensitive false;
        Gtk_utils.async ~parent:box (fun () ->
          try_lwt
            let url = entry#text in
            if url = "" then raise_safe "Enter a URL";
            begin match Feed_url.parse_non_distro url with
            | `local_feed _ -> raise_safe "Not a remote feed!"
            | `remote_feed _ as feed_url ->
                let config = tools#config in
                let fetcher = tools#make_fetcher (watcher :> Progress.watcher) in
                lwt () = Gui.add_remote_feed config fetcher iface feed_url in
                box#destroy ();
                recalculate ~force:false;
                Lwt.return () end
          with Safe_exception (msg, _) ->
            box#misc#set_sensitive true;
            error_label#set_text msg;
            error_label#misc#show ();
            entry#misc#grab_focus ();
            Lwt.return ()
        )
  );

  box#show ()

let add_local_feed ~parent ~recalculate config iface () =
  let box = GWindow.file_chooser_dialog
    ~parent
    ~action:`OPEN
    ~title:"Select XML feed file"
    () in

  box#set_current_folder config.system#getcwd |> ignore;

  box#add_button_stock `CANCEL `CANCEL;
  box#add_select_button_stock `OPEN `OK;

  box#connect#response ==> (function
    | `DELETE_EVENT | `CANCEL -> box#destroy ()
    | `OK ->
        try
          let path = box#filename |? lazy (raise_safe "No filename!") in
          match Feed_url.parse_non_distro path with
          | `remote_feed _ -> raise_safe "Not a local feed!"
          | `local_feed _ as feed_url ->
              Gui.add_feed config iface feed_url;
              box#destroy ();
              recalculate ~force:false
        with Safe_exception _ as ex -> Alert_box.report_error ~parent:box ex
  );

  box#show ()

let open_in_browser (system:system) url =
  let browser = default "firefox" (system#getenv "BROWSER") in
  system#spawn_detach ~search_path:true [browser; url]

let make_feeds_tab tools ~trust_db ~recalculate ~watcher window iface =
  let config = tools#config in

  (* Model *)
  let columns = new GTree.column_list in
  let url = columns#add Gobject.Data.string in
  let arch = columns#add Gobject.Data.string in
  let used = columns#add Gobject.Data.boolean in
  let feed_obj = columns#add Gobject.Data.caml in
  let feeds_model = GTree.list_store columns in

  (* View *)
  let vpaned = GPack.paned `VERTICAL () in

  (* Feed list *)
  let hbox = GPack.hbox ~packing:(vpaned#pack1 ~shrink:false) ~homogeneous:false () in
  let swin = GBin.scrolled_window
    ~packing:(hbox#pack ~expand:true ~fill:true)
    ~hpolicy:`NEVER
    ~vpolicy:`ALWAYS
    ~shadow_type:`IN
    ~border_width:4
    () in
  let view = GTree.view ~model:feeds_model ~packing:swin#add () in
  let renderer = GTree.cell_renderer_text [] in
  let source_col = GTree.view_column ~title:"Source" ~renderer:(renderer, ["text", url]) () in
  let arch_col = GTree.view_column ~title:"Arch" ~renderer:(renderer, ["text", arch]) () in
  source_col#add_attribute renderer "sensitive" used;
  arch_col#add_attribute renderer "sensitive" used;
  append_column view source_col;
  append_column view arch_col;
  let selection = view#selection in
  selection#set_mode `BROWSE;

  (* Feed buttons *)
  let button_box = GPack.button_box `VERTICAL ~packing:hbox#pack ~border_width:4 ~layout:`START () in
  let add_remote = GButton.button ~packing:button_box#pack ~label:"Add remote feed" () in
  let add_local = GButton.button ~packing:button_box#pack ~label:"Add local feed" () in
  let remove_feed = GButton.button ~packing:button_box#pack ~label:"Remove feed" () in

  add_remote#connect#clicked ==> (add_remote_feed ~parent:window ~watcher ~recalculate tools iface);
  add_local#connect#clicked ==> (add_local_feed ~parent:window ~recalculate config iface);
  remove_feed#connect#clicked ==> (fun () ->
    match selection#get_selected_rows with
    | [path] ->
        let iter = feeds_model#get_iter path in
        let feed_import = feeds_model#get ~row:iter ~column:feed_obj in
        Gui.remove_feed config iface feed_import.F.feed_src;
        remove_feed#misc#set_sensitive false;
        recalculate ~force:false;
    | _ -> log_warning "Impossible selection!"
  );

  (* Description *)
  let swin = GBin.scrolled_window
    ~packing:vpaned#pack2
    ~hpolicy:`AUTOMATIC
    ~vpolicy:`ALWAYS
    ~shadow_type:`IN
    ~border_width:4
    () in
  let text = GText.view
    ~packing:swin#add
    ~wrap_mode:`WORD
    ~editable:false
    ~cursor_visible:false
    () in
  text#set_left_margin 4;
  text#set_right_margin 4;
  let buffer = text#buffer in

  let heading_style = buffer#create_tag [`UNDERLINE `SINGLE; `SCALE `LARGE] in
  let link_style = buffer#create_tag [`UNDERLINE `SINGLE; `FOREGROUND "blue"] in

  let limit_updates = Limiter.make_limiter ~parent:window in  (* Prevent updates in parallel *)
  let clear () = buffer#delete ~start:buffer#start_iter ~stop:buffer#end_iter in

  (* Update description when a feed is selected *)
  selection#connect#changed ==> (fun () ->
    limit_updates (fun () ->
      match selection#get_selected_rows with
      | [] -> clear (); Lwt.return ()
      | [path] ->
          (* Only enable removing user_override feeds *)
          let iter = feeds_model#get_iter path in
          let feed_import = feeds_model#get ~row:iter ~column:feed_obj in
          remove_feed#misc#set_sensitive @@ (feed_import.F.feed_type = F.User_registered);
          begin match watcher#feed_provider#get_feed feed_import.F.feed_src with
          | None -> buffer#insert ~iter:buffer#start_iter "Not yet downloaded."; Lwt.return ()
          | Some (feed, overrides) ->
              lwt description = generate_feed_description config trust_db feed overrides in
              clear ();
              add_description_text config ~trust_db ~heading_style ~link_style buffer feed description end
      | _ -> log_warning "Multiple selection in browse mode!"; Lwt.return ()
    )
  );

  text#event#connect#button_press ==> (fun bev ->
    let module B = GdkEvent.Button in
    if GdkEvent.get_type bev = `BUTTON_PRESS && B.button bev = 1 then (
      let win_type = text#get_window_type (GdkEvent.get_window bev) in
      let x, y = text#window_to_buffer_coords ~tag:win_type ~x:(B.x bev |> truncate) ~y:(B.y bev |> truncate) in
      let iter = text#get_iter_at_location ~x ~y in
      if iter#has_tag link_style then (
        let start = iter#backward_to_tag_toggle (Some link_style) in
        let stop = iter#forward_to_tag_toggle (Some link_style) in
        let target = start#get_text ~stop |> trim in
        open_in_browser config.system target;
        true
      ) else false
    ) else false
  );

  text#misc#set_size_request ~width:(-1) ~height:100 ();

  object
    method widget = (vpaned :> GObj.widget)
    method update =
      let iface_config = watcher#feed_provider#get_iface_config iface in
      let extra_feeds = iface_config.FC.extra_feeds in

      let master_feed = Feed_url.master_feed_of_iface iface in
      let imported_feeds =
        match watcher#feed_provider#get_feed master_feed with
        | None -> []
        | Some (feed, _overrides) -> feed.F.imported_feeds in

      let main = F.({
        feed_src = master_feed;
        feed_os = None;
        feed_machine = None;
        feed_langs = None;
        feed_type = Feed_import;
      }) in

      feeds_model#clear ();
      (main :: (imported_feeds @ extra_feeds)) |> List.iter (fun feed ->
        let row = feeds_model#append () in
        let arch_value =
          match feed.F.feed_os, feed.F.feed_machine with
          | None, None -> ""
          | os, machine -> Arch.format_arch os machine in
        feeds_model#set ~row ~column:url (Feed_url.format_url feed.F.feed_src);
        feeds_model#set ~row ~column:arch arch_value;
        feeds_model#set ~row ~column:used (watcher#feed_provider#was_used feed.F.feed_src);
        feeds_model#set ~row ~column:feed_obj feed;
      );

      if selection#get_selected_rows = [] then (
        feeds_model#get_iter_first |> if_some selection#select_iter
      )
  end

let build_stability_menu set_stability =
  let menu = GMenu.menu () in

  let unset = GMenu.menu_item ~packing:menu#add ~label:"Unset" () in
  unset#connect#activate ==> (fun () -> set_stability None);

  GMenu.separator_item ~packing:menu#add () |> ignore_widget;

  [Preferred; Packaged; Stable; Testing; Developer; Buggy; Insecure] |> List.iter (fun stability ->
    let label = Impl.format_stability stability |> String.capitalize in
    let item = GMenu.menu_item ~packing:menu#add ~label () in
    item#connect#activate ==> (fun () -> set_stability (Some stability))
  );
  menu

let show_explanation_box ~parent iface version reason =
  let title = spf "%s version %s" iface version in
  if String.contains reason '\n' then (
    let box = GWindow.dialog
      ~parent
      ~title
      () in
    box#add_button_stock `CLOSE `CLOSE;

    let swin = GBin.scrolled_window
      ~packing:(box#vbox#pack ~expand:true)
      ~hpolicy:`AUTOMATIC
      ~vpolicy:`AUTOMATIC
    () in

    GMisc.label ~packing:swin#add_with_viewport ~text:reason () |> ignore_widget;

    box#set_default_size
      ~width:(Gdk.Screen.width () * 3 / 4)
      ~height:(Gdk.Screen.height () / 3);

    box#connect#response ==> (function
      | `DELETE_EVENT | `CLOSE -> box#destroy ()
    );
    box#show ()
  ) else (
    let box = GWindow.message_dialog
      ~parent
      ~title
      ~message:reason
      ~buttons:GWindow.Buttons.close
      ~message_type:`INFO
      () in
    box#connect#response ==> (function
      | `DELETE_EVENT | `CLOSE -> box#destroy ()
    );
    box#show ()
  )

let make_versions_tab config reqs ~recalculate ~watcher window iface =
  let vbox = GPack.vbox () in

  (* Stability policy *)
  let table = GPack.table
    ~columns:2 ~rows:1
    ~col_spacings:4
    ~border_width:4
    ~homogeneous:false ~packing:vbox#pack () in

  let set_stability_policy value =
    let iface_config = {FC.load_iface_config config iface with FC.stability_policy = value} in
    FC.save_iface_config config iface iface_config;
    recalculate ~force:false in

  let iface_config = FC.load_iface_config config iface in

  Preferences_box.combo
    ~table ~top:0 ~label:"Preferred stability: "
    ~choices:[None; Some Stable; Some Testing; Some Developer]
    ~value:iface_config.FC.stability_policy
    ~to_string:(function
      | None -> "Use default setting"
      | Some level -> Impl.format_stability level |> String.capitalize
    )
    ~callback:set_stability_policy
    ~tooltip:"Implementations at this stability level or higher will be used in preference to others. \
              You can use this to override the global \"Help test new versions\" setting just for this interface.";

  (* Implementation list *)
  let swin = GBin.scrolled_window
    ~packing:(vbox#pack ~expand:true)
    ~hpolicy:`NEVER
    ~vpolicy:`AUTOMATIC
    ~shadow_type:`IN
    ~border_width:4
    () in

  (* Model *)
  let cols = new GTree.column_list in
  let item =    cols#add Gobject.Data.caml in
  let arch =    cols#add Gobject.Data.string in
  let stability = cols#add Gobject.Data.string in
  let version = cols#add Gobject.Data.string in
  let fetch =   cols#add Gobject.Data.string in
  let unusable = cols#add Gobject.Data.boolean in
  let released = cols#add Gobject.Data.string in
  let notes =   cols#add Gobject.Data.string in
  let weight =  cols#add Gobject.Data.int in (* Selected item is bold *)
  let langs =   cols#add Gobject.Data.string in
  let tooltip = cols#add Gobject.Data.string in
  let model = GTree.list_store cols in

  (* View *)
  let view = GTree.view ~model:model ~packing:swin#add () in
  view#set_tooltip_column tooltip.GTree.index;

  let cell_text = GTree.cell_renderer_text [] in
  let cell_text_strike = GTree.cell_renderer_text [] in

  let add_column title ?(strike=false) column =
    let cell = if strike then cell_text_strike else cell_text in
    let view_col = GTree.view_column ~title ~renderer:(cell, ["text", column]) () in
    view_col#add_attribute cell "weight" weight;
    if strike then view_col#add_attribute cell "strikethrough" unusable;
    append_column view view_col in

  add_column "Version" ~strike:true version;
  add_column "Released" released;
  add_column "Stability" stability;
  add_column "Fetch" ~strike:true fetch;
  add_column "Arch" ~strike:true arch;
  add_column "Lang" langs;
  add_column "Notes" notes;

  view#event#connect#button_press ==> (fun bev ->
    let module B = GdkEvent.Button in
    match GdkEvent.get_type bev, B.button bev with
    | `BUTTON_PRESS, (1 | 3) ->
        begin match view#get_path_at_pos ~x:(B.x bev |> truncate) ~y:(B.y bev |> truncate) with
        | None -> false
        | Some (path, _col, _x, _y) ->
            let row = model#get_iter path in
            let impl = model#get ~row ~column:item in
            let version_str = model#get ~row ~column:version in
            let menu = GMenu.menu () in
            let stability_menu = GMenu.menu_item ~packing:menu#add ~label:"Rating" () in
            let submenu = build_stability_menu (fun stability ->
              Gui.set_impl_stability config (Impl.get_id impl) stability;
              recalculate ~force:false
            ) in
            stability_menu#set_submenu submenu;

            let add_open_item path =
              let item = GMenu.menu_item ~packing:menu#add ~label:"Open in file manager" () in
              item#connect#activate ==> (fun () ->
                U.xdg_open_dir config.system path
              ) in
            begin match impl.Impl.impl_type with
            | `local_impl path -> add_open_item path
            | `cache_impl info ->
                let path = Stores.lookup_maybe config.system info.Impl.digests config.stores in
                path |> if_some add_open_item
            | `package_impl _ -> () end;

            let explain = GMenu.menu_item ~packing:menu#add ~label:"Explain this decision" () in
            explain#connect#activate ==> (fun () ->
              let reason = Justify.justify_decision config watcher#feed_provider reqs iface (Impl.get_id impl) in
              show_explanation_box ~parent:window iface version_str reason
            );
            menu#popup ~button:(B.button bev) ~time:(B.time bev);
            true end
    | _ -> false
  );

  object
    method widget = vbox#coerce
    method update =
      model#clear ();
      let (_ready, result) = watcher#results in
      match Gui.list_impls result iface with
      | None -> view#misc#set_sensitive false
      | Some (selected, impls) ->
          view#misc#set_sensitive true;

          let get_overrides =
            let cache = ref StringMap.empty in
            fun feed ->
              match !cache |> StringMap.find feed with
              | Some result -> result
              | None ->
                  let result = F.load_feed_overrides config (Feed_url.parse feed) in
                  cache := !cache |> StringMap.add feed result;
                  result in

          impls |> List.iter (fun (impl, problem) ->
            let from_feed = Impl.get_attr_ex FeedAttr.from_feed impl in
            let impl_id = Impl.get_attr_ex FeedAttr.id impl in
            let overrides = get_overrides from_feed in
            let stability_value =
              match StringMap.find impl_id overrides.F.user_stability with
              | Some user_stability -> Impl.format_stability user_stability |> String.uppercase
              | None -> Q.AttrMap.get_no_ns FeedAttr.stability impl.Impl.props.Impl.attrs |> default "testing" in

            let arch_value =
              match impl.Impl.os, impl.Impl.machine with
              | None, None -> "any"
              | os, machine -> Arch.format_arch os machine in

            let notes_value =
              match problem with
              | None -> "None"
              | Some problem -> Impl_provider.describe_problem impl problem in

            let (fetch_str, fetch_tip) = Gui.get_fetch_info config impl in

            let row = model#append () in
            model#set ~row ~column:version @@ Versions.format_version impl.Impl.parsed_version;
            model#set ~row ~column:released @@ default "-" @@ Q.AttrMap.get_no_ns FeedAttr.released impl.Impl.props.Impl.attrs;
            model#set ~row ~column:stability @@ stability_value;
            model#set ~row ~column:langs @@ default "-" @@ Q.AttrMap.get_no_ns FeedAttr.langs impl.Impl.props.Impl.attrs;
            model#set ~row ~column:arch arch_value;
            model#set ~row ~column:notes notes_value;
            model#set ~row ~column:weight (if Some impl = selected then 700 else 400);
            model#set ~row ~column:unusable (problem <> None);
            model#set ~row ~column:fetch fetch_str;
            model#set ~row ~column:tooltip fetch_tip;
            model#set ~row ~column:item impl;
          )
  end

let create tools ~trust_db reqs iface ~recalculate ~select_versions_tab ~watcher =
  let config = tools#config in
  let title = Printf.sprintf "Properties for %s" iface in
  let dialog = GWindow.dialog ~title () in
  dialog#set_default_size
    ~width:(-1)
    ~height:(Gdk.Screen.height () / 3);

  (* Tabs *)
  let notebook = GPack.notebook ~packing:(dialog#vbox#pack ~expand:true ~fill:true) () in
  let label text = (GMisc.label ~text () :> GObj.widget) in
  let feeds_tab = make_feeds_tab tools ~trust_db ~recalculate ~watcher dialog iface in
  let versions_tab = make_versions_tab config reqs ~recalculate ~watcher dialog iface in
  append_page notebook ~tab_label:(label "Feeds") (feeds_tab#widget);
  append_page notebook ~tab_label:(label "Versions") (versions_tab#widget);

  if select_versions_tab then notebook#next_page ();

  (* Buttons *)
  dialog#add_button_stock `HELP `HELP;
  (* Lablgtk uses the wrong response code for HELP, so we have to do this manually. *)
  let actions = dialog#action_area in
  actions#set_child_secondary (List.hd actions#children) true;

  dialog#add_button "Compile" `COMPILE;
  dialog#add_button_stock `CLOSE `CLOSE;
  dialog#set_default_response `CLOSE;

  dialog#set_response_sensitive `COMPILE false;

  dialog#connect#response ==> (function
    | `COMPILE ->
        Gtk_utils.async ~parent:dialog (fun () ->
          lwt () = Gui.compile config watcher#feed_provider iface ~autocompile:true in
          recalculate ~force:false;
          Lwt.return ()
        )
    | `DELETE_EVENT | `CLOSE -> dialog#destroy ()
    | `HELP -> component_help#display
  );

  object
    method dialog = dialog
    method update : unit =
      dialog#set_response_sensitive `COMPILE (Gui.have_source_for watcher#feed_provider iface);
      feeds_tab#update;
      versions_tab#update
  end
