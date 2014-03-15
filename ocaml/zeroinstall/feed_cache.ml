(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Caching downloaded feeds on disk *)

open General
open Support.Common
module Q = Support.Qdom
module U = Support.Utils
module Basedir = Support.Basedir
module FeedSet = Feed_url.FeedSet
open Constants

type interface_config = {
  stability_policy : stability_level option;
  extra_feeds : Feed.feed_import list;
}

(* If we started a check within this period, don't start another one *)
let failed_check_delay = 1. *. hours

let get_cached_feed_path config (`remote_feed url) =
  let cache = config.basedirs.Basedir.cache in
  Basedir.load_first config.system (config_site +/ "interfaces" +/ Escape.escape url) cache

let get_save_cache_path config (`remote_feed url) =
  let cache = config.basedirs.Support.Basedir.cache in
  let dir = Support.Basedir.save_path config.system (config_site +/ "interfaces") cache in
  dir +/ Escape.escape url

let get_cached_icon_path config feed_url =
  let (`remote_feed url | `local_feed url) = feed_url in
  Basedir.load_first config.system (cache_icons +/ Escape.escape url) config.basedirs.Basedir.cache

let list_all_feeds config =
  let feeds = ref StringSet.empty in
  let system = config.system in

  let check_leaf leaf =
    if leaf.[0] <> '.' then
      let uri = Escape.unescape leaf in
      feeds := StringSet.add uri !feeds in

  let scan_dir path =
    match system#readdir (path +/ config_site +/ "interfaces") with
    | Problem _ -> ()
    | Success files -> Array.iter check_leaf files in

  List.iter scan_dir config.basedirs.Basedir.cache;

  !feeds

(* Note: this was called "update_user_overrides" in the Python *)
let load_iface_config config uri : interface_config =
  let get_site_feed dir =
    if config.system#file_exists dir then (
      match config.system#readdir dir with
      | Success items ->
          items |> U.filter_map_array (fun impl ->
            if U.starts_with impl "." then None
            else (
              let feed = dir +/ impl +/ "0install" +/ "feed.xml" in
              if not (config.system#file_exists feed) then (
                log_warning "Site-local feed %s not found" feed;
                None
              ) else  (
                log_debug "Adding site-local feed '%s'" feed;
                let open Feed in
                Some { feed_src = `local_feed feed; feed_os = None; feed_machine = None; feed_langs = None; feed_type = Site_packages }
              )
            )
          )
      | Problem ex ->
          log_warning ~ex "Failed to read '%s'" dir;
          []
    ) else []
  in

  try
    (* Distribution-provided feeds *)
    let distro_feeds =
      match Basedir.load_first config.system (data_native_feeds +/ Escape.pretty uri) config.basedirs.Basedir.data with
      | None -> []
      | Some path ->
          log_info "Adding native packager feed '%s'" path;
          (* Resolve any symlinks *)
          let open Feed in [{
            feed_src = `local_feed (U.realpath config.system path);
            feed_os = None; feed_machine = None; feed_langs = None; feed_type = Distro_packages
          }]
      in

    (* Local feeds in the data directory (e.g. builds created with 0compile) *)
    let site_feeds =
      let rel_path = data_site_packages +/ (String.concat Filename.dir_sep @@ Escape.escape_interface_uri uri) in
      List.concat @@ List.map (fun dir -> get_site_feed @@ dir +/ rel_path) config.basedirs.Basedir.data in

    let load config_file =
      let root = Q.parse_file config.system config_file in
      let stability_policy =
        match ZI.get_attribute_opt IfaceConfigAttr.stability_policy root with
        | None -> None
        | Some s -> Some (Feed.parse_stability s ~from_user:true) in

      (* User-registered feeds (0install add-feed) *)
      let known_site_feeds = List.fold_left (fun map feed -> FeedSet.add feed.Feed.feed_src map) FeedSet.empty site_feeds in
      let user_feeds =
        root |> ZI.filter_map (fun item ->
          match ZI.tag item with
          | Some "feed" -> (
              let feed_src = ZI.get_attribute "src" item |> Feed_url.parse_non_distro in
              (* (note: 0install 1.9..1.12 used a different scheme and the "site-package" attribute;
                 we deliberately use a different attribute name to avoid confusion) *)
              if ZI.get_attribute_opt IfaceConfigAttr.is_site_package item <> None then (
                (* Site packages are detected earlier. This test isn't completely reliable,
                   since older versions will remove the attribute when saving the config
                   (hence the next test). *)
                None
              ) else if FeedSet.mem feed_src known_site_feeds then (
                None
              ) else (
                let (feed_os, feed_machine) = match ZI.get_attribute_opt "arch" item with
                | None -> (None, None)
                | Some arch -> Arch.parse_arch arch in
                let feed_langs = match ZI.get_attribute_opt "langs" item with
                | None -> None
                | Some langs -> Some (Str.split U.re_space langs) in
                let open Feed in
                Some { feed_src; feed_os; feed_machine; feed_langs; feed_type = User_registered }
              )
          )
          | _ -> None
        ) in

      { stability_policy; extra_feeds = distro_feeds @ site_feeds @ user_feeds; } in

    match Config.load_first_config (config_injector_interfaces +/ Escape.pretty uri) config with
    | Some path -> load path
    | None ->
        (* For files saved by 0launch < 0.49 *)
        match Config.load_first_config (config_site +/ config_prog +/ "user_overrides" +/ Escape.escape uri) config with
        | None -> { stability_policy = None; extra_feeds = distro_feeds @ site_feeds }
        | Some path -> load path
  with Safe_exception _ as ex -> reraise_with_context ex "... reading configuration settings for interface %s" uri

let add_import_elem feed_import =
  match feed_import.Feed.feed_type with
  | Feed.Distro_packages | Feed.Feed_import -> None
  | Feed.User_registered | Feed.Site_packages ->
      let attrs = ref (Q.AttrMap.singleton IfaceConfigAttr.src (Feed_url.format_url feed_import.Feed.feed_src)) in
      if feed_import.Feed.feed_type = Feed.Site_packages then
        attrs := !attrs |> Q.AttrMap.add_no_ns IfaceConfigAttr.is_site_package "True";
      begin match feed_import.Feed.feed_os, feed_import.Feed.feed_machine with
      | None, None -> ()
      | os, machine ->
          let arch = Arch.format_arch os machine in
          attrs := !attrs |> Q.AttrMap.add_no_ns IfaceConfigAttr.arch arch end;
      Some (ZI.make ~attrs:!attrs "feed")

let save_iface_config config uri iface_config =
  let config_dir = Basedir.save_path config.system config_injector_interfaces config.basedirs.Basedir.config in

  let attrs = ref (Q.AttrMap.singleton FeedAttr.uri uri) in
  iface_config.stability_policy |> if_some (fun policy ->
    attrs := !attrs |> Q.AttrMap.add_no_ns IfaceConfigAttr.stability_policy (Feed.format_stability policy)
  );

  let child_nodes = iface_config.extra_feeds |> U.filter_map add_import_elem in
  let root = ZI.make ~attrs:!attrs ~child_nodes "interface-preferences" in

  config_dir +/ Escape.pretty uri |> config.system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
    Q.output (`Channel ch |> Xmlm.make_output) root;
  )

let get_cached_feed config = function
  | `local_feed path -> (
      try
        let root = Q.parse_file config.system path in
        Some (Feed.parse config.system root (Some path))
      with Safe_exception _ as ex ->
        log_warning ~ex "Can't read local file '%s'" path;
        None
  )
  | `remote_feed url as remote_feed ->
      match get_cached_feed_path config remote_feed with
      | None -> None
      | Some path ->
          let root = Q.parse_file config.system path in
          let feed = Feed.parse config.system root None in
          if feed.Feed.url = remote_feed then Some feed
          else raise_safe "Incorrect URL in cached feed - expected '%s' but found '%s'" url (Feed_url.format_url feed.Feed.url)

let get_last_check_attempt config (`remote_feed url) =
  let open Basedir in
  let rel_path = config_site +/ config_prog +/ "last-check-attempt" +/ Escape.pretty url in
  match load_first config.system rel_path config.basedirs.cache with
  | None -> None
  | Some path ->
      match config.system#stat path with
      | None -> None
      | Some info -> Some info.Unix.st_mtime

let internal_is_stale config (`remote_feed url as feed_url) overrides =
  let now = config.system#time in

  let is_stale () =
    match get_last_check_attempt config feed_url with
    | Some last_check_attempt when last_check_attempt > now -. failed_check_delay ->
        log_debug "Stale, but tried to check recently (%s) so not rechecking now." (U.format_time (Unix.localtime last_check_attempt));
        false
    | _ -> true in

  match overrides with
  | None -> is_stale ()
  | Some overrides ->
      match overrides.Feed.last_checked with
      | None ->
          log_debug "Feed '%s' has no last checked time, so needs update" url;
          is_stale ()
      | Some checked ->
          let staleness = now -. checked in
          log_debug "Staleness for %s is %.2f hours" url (staleness /. 3600.0);

          match config.freshness with
          | None -> log_debug "Checking for updates is disabled"; false
          | Some threshold when staleness >= threshold -> is_stale ()
          | _ -> false

let is_stale config url =
  let overrides = Feed.load_feed_overrides config url in
  internal_is_stale config url (Some overrides)

let mark_as_checking config (`remote_feed url) =
  let timestampts_dir = Basedir.save_path config.system cache_last_check_attempt config.basedirs.Basedir.cache in
  let timestamp_path = timestampts_dir +/ Escape.pretty url in
  U.touch config.system timestamp_path
