(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
open Support.Common
open Gtk_common
open Zeroinstall.General
module G = Support.Gpg

let get_keys_by_domain gpg trust_db =
  let domains_of_key = trust_db#get_db in
  let fingerprints = domains_of_key |> XString.Map.map_bindings (fun key _domains -> key) in
  G.load_keys gpg fingerprints >|= fun key_info ->
  let keys_of_domain = ref XString.Map.empty in
  domains_of_key |> XString.Map.iter (fun key domains ->
    domains |> XString.Set.iter (fun domain ->
      let keys = default [] @@ XString.Map.find_opt domain !keys_of_domain in
      keys_of_domain := !keys_of_domain |> XString.Map.add domain (key :: keys)
    )
  );
  (key_info, !keys_of_domain)

let preferences_help = Help_box.create "0install Preferences Help" [
("Overview",
"There are three ways to control which implementations are chosen. You can adjust the \
network policy and the overall stability policy, which affect all interfaces, or you \
can edit the policy of individual interfaces.");

("Network use",
"The 'Network use' option controls how 0install uses the network. If off-line, \
the network is not used at all. If 'Minimal' is selected then 0install will use \
the network if needed, but only if it has no choice. It will run an out-of-date \
version rather than download a newer one. If 'Full' is selected, 0install won't \
worry about how much it downloads, but will always pick the version it thinks is best.");

("Freshness",
"The feed files, which provide the information about which versions are \
available, are also cached. To update them, click on 'Refresh all now'. You can also \
get 0install to check for new versions automatically from time to time using \
the Freshness setting.");

("Help test new versions",
"The overall stability policy can either be to prefer stable versions, or to help test \
new versions. Choose whichever suits you. Since different programmers have different \
ideas of what 'stable' means, you may wish to override this on a per-interface basis.\
\n\n\
To set the policy for an interface individually, double-click on it in the main window and \
use the \"Preferred stability\" control.");

("Security",
"This section lists all keys which you currently trust. When fetching a new program or \
updates for an existing one, the feed must be signed by one of these keys. If not, \
you will be prompted to confirm that you trust the new key, and it will then be added \
to this list.\
\n\n\
If \"Automatic approval for new feeds\" is on, new keys will be automatically approved if \
you haven't used the program before and the key is known to the key information server. \
When updating feeds, confirmation for new keys is always required.\
\n\n\
To remove a key, right-click on it and choose 'Remove' from the menu.")
]

let frame ~packing ~title =
  let frame = GBin.frame ~packing ~shadow_type:`NONE () in
  let label = GMisc.label
    ~markup:(Printf.sprintf "<b>%s</b>" title)    (* Escaping? *)
    () in
  frame#set_label_widget (Some (label :> GObj.widget));
  frame


let freshness_levels = [
  (None, "No automatic updates");
  (Some (1. *. days), "Up to one day old");
  (Some (7. *. days), "Up to one week old");
  (Some (30. *. days), "Up to one month old");
  (Some (365. *. days), "Up to one year old");
]

let find_open_rows (view:GTree.view) column =
  let model = view#model in
  match model#get_iter_first with
  | None -> XString.Set.empty
  | Some iter ->
      let results = ref XString.Set.empty in
      let rec loop () =
        if model#get_path iter |> view#row_expanded then (
          results := !results |> XString.Set.add (model#get ~row:iter ~column);
        );
        if model#iter_next iter then loop ()
      in
      loop ();
      !results

let add_key_list ~packing gpg trust_db =
  let swin = GBin.scrolled_window
    ~packing
    ~hpolicy:`AUTOMATIC
    ~vpolicy:`ALWAYS
    ~shadow_type:`IN
    ~border_width:2
    () in

  (* Model *)
  let cols = new GTree.column_list in
  let fingerprint = cols#add Gobject.Data.string in
  let name = cols#add Gobject.Data.string in
  let model = GTree.tree_store cols in

  (* View *)
  let view = GTree.view ~model ~packing:swin#add () in
  let renderer = GTree.cell_renderer_text [] in
  let view_col = GTree.view_column ~title:"Trusted keys" ~renderer:(renderer, ["text", name]) () in
  append_column view view_col;

  (* Handle events *)
  view#event#connect#button_press ==> (fun bev ->
    let module B = GdkEvent.Button in
    if GdkEvent.get_type bev = `BUTTON_PRESS && B.button bev = 3 then (
      match view#get_path_at_pos ~x:(B.x bev |> truncate) ~y:(B.y bev |> truncate) with
      | None -> false
      | Some (path, _col, _x, _y) ->
          if GtkTree.TreePath.get_depth path = 2 then (
            let iter = model#get_iter path in
            let key = model#get ~row:iter ~column:name in
            let fpr = model#get ~row:iter ~column:fingerprint in
            let iter = model#iter_parent iter |? lazy (failwith "No parent!") in
            let domain = model#get ~row:iter ~column:name in
            let menu = GMenu.menu () in
            let item = GMenu.menu_item ~packing:menu#add ~label:(Printf.sprintf "Remove key for \"%s\"" key) () in
            item#connect#activate ==> (fun () -> trust_db#untrust_key ~domain fpr);
            menu#popup ~button:(B.button bev) ~time:(B.time bev);
            true
          ) else false
    ) else false
  );

  (* Populate model *)
  let populate_model () =
    get_keys_by_domain gpg trust_db >|= fun (key_info, keys_of_domain) ->

    (* Remember which ones are open *)
    let previously_open = find_open_rows view name in

    model#clear ();

    keys_of_domain |> XString.Map.iter (fun domain keys ->
      let domain_row = model#append () in
      model#set ~row:domain_row ~column:name domain;

      keys |> List.iter (fun key ->
        let key_row = model#append ~parent:domain_row () in
        let key_name = XString.Map.find_opt key key_info |> pipe_some (fun info -> info.G.name) |> default key in
        model#set ~row:key_row ~column:fingerprint key;
        model#set ~row:key_row ~column:name key_name
      )
    );

    model#get_iter_first |> if_some (fun iter ->
      let rec loop () =
        if XString.Set.mem (model#get ~row:iter ~column:name) previously_open then
          view#expand_row (model#get_path iter);
        if model#iter_next iter then loop () in
      loop ()
    ) in

  let unregister = trust_db#add_watcher (object method notify = Gtk_utils.async populate_model end) in
  view#connect#destroy ==> unregister;

  Gtk_utils.async populate_model

let make config trust_db ~recalculate =
  let apply_changes () =
    Zeroinstall.Config.save_config config;
    recalculate () in

  let dialog = GWindow.dialog ~title:"0install Preferences" () in
  dialog#action_area#set_border_width 4;
  let vbox = GPack.vbox ~border_width:12 ~packing:(dialog#vbox#pack ~expand:true) () in

  let policy_settings = frame ~packing:(vbox#pack ~expand:false) ~title:"Policy settings" in

  let table = GPack.table
    ~columns:2 ~rows:3
    ~row_spacings:4 ~col_spacings:4
    ~homogeneous:false ~border_width:12 ~packing:policy_settings#add () in

  (* Network use *)
  Gtk_utils.combo
    ~table ~top:0 ~label:"Network use: "
    ~choices:[Offline; Minimal_network; Full_network] ~value:config.network_use
    ~to_string:(fun n -> Zeroinstall.Config.format_network_use n |> String.capitalize_ascii)
    ~callback:(fun network_use -> config.network_use <- network_use; apply_changes ())
    ~tooltip:"This controls whether Zero Install will always try to run the best version, downloading it if needed, \
              or whether it will prefer to run an older version that is already on your machine.";

  (* Freshness *)
  let freshness_levels, current_freshness =
    try (freshness_levels, List.find (fun (f, _) -> f = config.freshness) freshness_levels)
    with Not_found ->
      let extra_choice = (config.freshness, Printf.sprintf "%.0f seconds" (default 0. config.freshness)) in
      (freshness_levels @ [extra_choice], extra_choice) in
  Gtk_utils.combo
    ~table ~top:1 ~label:"Freshness: "
    ~choices:freshness_levels ~value:current_freshness
    ~to_string:snd
    ~callback:(fun (freshness, _) -> config.freshness <- freshness; apply_changes ())
    ~tooltip:"If you run a program which hasn't been checked for this long, then Zero Install will check \
              for updates (in the background, while the old version is actually run).";

  (* Help with testing *)
  let help_with_testing = GButton.check_button
    ~packing:(table#attach ~left:0 ~right:2 ~top:2 ~expand:`X)
    ~active:config.help_with_testing
    ~label:"Help test new versions"
    () in
  help_with_testing#misc#set_tooltip_text
    "Try out new versions as soon as they are available, instead of waiting for them to be marked as 'stable'. \
     This sets the default policy. Choose 'Show Versions' from the menu in the main window to set the policy \
     for an individual component.";
  help_with_testing#connect#toggled ==> (fun () ->
    config.help_with_testing <- help_with_testing#active; apply_changes ()
  );

  (* Keys *)
  let security_settings = frame ~packing:(vbox#pack ~expand:true ~fill:true) ~title:"Security" in
  let vbox = GPack.vbox ~border_width:12 ~packing:security_settings#add () in
  GMisc.label ~packing:vbox#pack ~xalign:0.0 ~markup:"<i>These keys may sign software updates:</i>" () |> ignore_widget;

  let gpg = G.make config.system in
  add_key_list ~packing:(vbox#pack ~expand:true ~fill:true) gpg trust_db;

  let auto_approve = GButton.check_button
    ~packing:vbox#pack
    ~active:config.auto_approve_keys
    ~label:"Automatic approval for new feeds"
    () in
  auto_approve#misc#set_tooltip_text
    "When fetching a feed for the first time, if the key is known to the key information server then \
     approve it automatically without confirmation.";
  auto_approve#connect#toggled ==> (fun () ->
    config.auto_approve_keys <- auto_approve#active; apply_changes ()
  );

  (* Buttons *)
  dialog#add_button_stock `HELP `HELP;
  (* Lablgtk uses the wrong response code for HELP, so we have to do this manually. *)
  let actions = dialog#action_area in
  actions#set_child_secondary (List.hd actions#children) true;
  dialog#add_button_stock `CLOSE `CLOSE;

  dialog#set_default_response `CLOSE;

  let result, set_result = Lwt.wait () in
  dialog#connect#response ==> (function
    | `DELETE_EVENT | `CLOSE -> Lwt.wakeup set_result (); dialog#destroy ()
    | `HELP -> preferences_help#display
  );

  dialog#set_default_size ~width:(-1) ~height:(Gdk.Screen.height () / 3);
  ((dialog :> GWindow.window_skel), result)
