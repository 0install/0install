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

let handle options flags args =
  let tools = options.tools in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  let gui = tools#ui in
  let config = options.config in

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
