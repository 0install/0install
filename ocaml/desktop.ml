(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Options
open Support.Common
open Zeroinstall.General

module FeedAttr = Zeroinstall.Constants.FeedAttr
module U = Support.Utils
module F = Zeroinstall.Feed
module Q = Support.Qdom

(** Use [xdg-open] to show the help files for this implementation. *)
let show_help config sel =
  let system = config.system in
  let help_dir = ZI.get_attribute_opt FeedAttr.doc_dir sel in
  let id = ZI.get_attribute FeedAttr.id sel in

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
      let path = Zeroinstall.Selections.get_path system config.stores sel |? lazy (raise_safe "BUG: not cached!") in
      match help_dir with
      | Some help_dir -> path +/ help_dir
      | None ->
          match Zeroinstall.Command.get_command "run" sel with
          | None -> path
          | Some run ->
              match ZI.get_attribute_opt "path" run with
              | None -> path
              | Some main ->
                  (* Hack for ROX applications. They should be updated to set doc-dir. *)
                  let help_dir = path +/ (Filename.dirname main) +/ "Help" in
                  if U.is_dir system help_dir then help_dir
                  else path
    ) in
  U.xdg_open_dir ~exec:true system path

let handle_help options flags args =
  let select_opts = ref [] in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
    | #select_option | `Refresh as o -> select_opts := o :: !select_opts
  );
  match args with
  | [arg] ->
      let sels = Generic_select.handle options !select_opts arg `Download_only in
      let index = Zeroinstall.Selections.make_selection_map sels in
      let root = ZI.get_attribute "interface" sels in
      let sel = StringMap.find_safe root index in
      show_help options.config sel
  | _ -> raise (Support.Argparse.Usage_error 1)

let handle options flags args =
  let tools = options.tools in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  let gui =
    match tools#ui with
    | Zeroinstall.Gui.Gui gui -> gui
    | Zeroinstall.Gui.Ui _ -> raise_safe "GUI not available" in
  let config = options.config in

  Zeroinstall.Python.register_handler "show-help" (function
    | [`String uri] ->
        config.system#spawn_detach ~search_path:false [config.abspath_0install; "_show_help"; uri];
        Lwt.return `Null
        (* (select uses a recursive Lwt_main, so deadlocks at the moment; need to port distro.py first)
        let requirements = Zeroinstall.Requirements.default_requirements uri in
        let sels = Generic_select.get_selections options ~refresh:false requirements `Download_only in
        begin match sels with
        | None -> Lwt.return `Null    (* Aborted by user *)
        | Some sels ->
            let index = Zeroinstall.Selections.make_selection_map sels in
            let root = ZI.get_attribute "interface" sels in
            let sel = StringMap.find root index in
            show_help config sel;
            Lwt.return `Null end
*)
    | json -> raise_safe "show-help: invalid request: %s" (Yojson.Basic.to_string (`List json))
  );

  Zeroinstall.Python.register_handler "get-feed-metadata" (function
    | [`String user_uri] -> begin
        let iface_uri = Generic_select.canonical_iface_uri config.system user_uri in
        let feed_url = Zeroinstall.Feed_url.master_feed_of_iface iface_uri in
        match Zeroinstall.Feed_cache.get_cached_feed config feed_url with
        | None -> raise_safe "Feed '%s' not cached!" iface_uri
        | Some feed ->
            let category =
              try
                let elem = feed.F.root.Q.child_nodes |> List.find (fun node -> ZI.tag node = Some "category") in
                `String elem.Q.last_text_inside
              with Not_found -> `Null in
            let needs_terminal = feed.F.root.Q.child_nodes |> List.exists (fun node -> ZI.tag node = Some "needs-terminal") in
            let icon_path =
              match Zeroinstall.Feed_cache.get_cached_icon_path config feed_url with
              | None -> `Null
              | Some path -> `String path in
            Lwt.return (`Assoc [
              ("url", `String iface_uri);
              ("name", `String feed.F.name);
              ("summary", `String (F.get_summary config.langs feed |? lazy "-"));
              ("needs-terminal", `Bool needs_terminal);
              ("icon-path", icon_path);
              ("category", category);
            ]) end
    | json -> raise_safe "get-feed-metadata: invalid request: %s" (Yojson.Basic.to_string (`List json))
  );

  let finished =
    match args with
    | [] ->
        gui#open_app_list_box;
    | [arg] ->
        let url = Generic_select.canonical_iface_uri config.system arg in
        gui#open_add_box url
    | _ -> raise (Support.Argparse.Usage_error 1) in

  Lwt_main.run finished
