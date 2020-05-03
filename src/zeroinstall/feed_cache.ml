(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Caching downloaded feeds on disk *)

open General
open Support
open Support.Common
module Q = Support.Qdom
module U = Support.Utils
module FeedSet = Feed_url.FeedSet
open Constants

type interface_config = {
  stability_policy : Stability.t option;
  extra_feeds : Feed_import.t list;
}

(* If we started a check within this period, don't start another one *)
let failed_check_delay = 1. *. hours

let get_cached_feed_path config url =
  Paths.Cache.(first (feed url)) config.paths

let get_save_cache_path config url =
  Paths.Cache.(save_path (feed url)) config.paths

let get_cached_icon_path config feed_url =
  Paths.Cache.(first (icon feed_url)) config.paths

let list_all_feeds config =
  let results = ref XString.Set.empty in
  let system = config.system in
  let check_leaf leaf =
    if leaf.[0] <> '.' then
      let uri = Escape.unescape leaf in
      results := XString.Set.add uri !results in
  let scan_dir path =
    match system#readdir path with
    | Error _ -> ()
    | Ok files -> Array.iter check_leaf files in
  List.iter scan_dir (Paths.Cache.(all_paths feeds) config.paths);
  !results

(* Note: this was called "update_user_overrides" in the Python *)
let load_iface_config config uri : interface_config =
  let get_site_feeds dir =
    if config.system#file_exists dir then (
      match config.system#readdir dir with
      | Ok items ->
          items |> U.filter_map_array (fun impl ->
            if XString.starts_with impl "." then None
            else (
              let feed = dir +/ impl +/ "0install" +/ "feed.xml" in
              if not (config.system#file_exists feed) then (
                log_warning "Site-local feed %s not found" feed;
                None
              ) else  (
                log_debug "Adding site-local feed '%s'" feed;
                Some { Feed_import.src = `Local_feed feed; os = None; machine = None; langs = None; ty = Site_packages }
              )
            )
          )
      | Error ex ->
          log_warning ~ex "Failed to read '%s'" dir;
          []
    ) else []
  in

  try
    (* Distribution-provided feeds *)
    let distro_feeds =
      match Paths.Data.(first (native_feed uri)) config.paths with
      | None -> []
      | Some path ->
          log_info "Adding native packager feed '%s'" path;
          (* Resolve any symlinks *)
          [{ Feed_import.
             src = `Local_feed (U.realpath config.system path);
             os = None; machine = None; langs = None; ty = Distro_packages
          }]
      in

    (* Local feeds in the data directory (e.g. builds created with 0compile) *)
    let site_feeds =
      Paths.Data.(all_paths (site_packages uri)) config.paths
      |> List.map get_site_feeds
      |> List.concat in

    let load config_file =
      let root = Q.parse_file config.system config_file in
      let stability_policy =
        match ZI.get_attribute_opt IfaceConfigAttr.stability_policy root with
        | None -> None
        | Some s -> Some (Stability.of_string s ~from_user:true) in

      (* User-registered feeds (0install add-feed) *)
      let known_site_feeds = List.fold_left (fun map feed -> FeedSet.add feed.Feed_import.src map) FeedSet.empty site_feeds in
      let user_feeds =
        root |> ZI.filter_map (fun item ->
          match ZI.tag item with
          | Some "feed" -> (
              let src = ZI.get_attribute "src" item |> Feed_url.parse_non_distro in
              (* (note: 0install 1.9..1.12 used a different scheme and the "site-package" attribute;
                 we deliberately use a different attribute name to avoid confusion) *)
              if ZI.get_attribute_opt IfaceConfigAttr.is_site_package item <> None then (
                (* Site packages are detected earlier. This test isn't completely reliable,
                   since older versions will remove the attribute when saving the config
                   (hence the next test). *)
                None
              ) else if FeedSet.mem src known_site_feeds then (
                None
              ) else (
                let (os, machine) = match ZI.get_attribute_opt "arch" item with
                | None -> (None, None)
                | Some arch -> Arch.parse_arch arch in
                let langs = match ZI.get_attribute_opt "langs" item with
                  | None -> None
                  | Some langs -> Some (Str.split XString.re_space langs) in
                Some { Feed_import.src; os; machine; langs; ty = User_registered }
              )
          )
          | _ -> None
        ) in

      { stability_policy; extra_feeds = distro_feeds @ site_feeds @ user_feeds; } in

    match Paths.Config.(first (interface uri)) config.paths with
    | Some path -> load path
    | None ->
        (* For files saved by 0launch < 0.49 *)
        match Paths.Config.(first (user_overrides uri)) config.paths with
        | None -> { stability_policy = None; extra_feeds = distro_feeds @ site_feeds }
        | Some path -> load path
  with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... reading configuration settings for interface %s" uri

let add_import_elem feed_import =
  let open Feed_import in
  match feed_import.ty with
  | Distro_packages | Feed_import -> None
  | User_registered | Site_packages ->
      let attrs = ref (Q.AttrMap.singleton IfaceConfigAttr.src (Feed_url.format_url feed_import.src)) in
      if feed_import.Feed_import.ty = Feed_import.Site_packages then
        attrs := !attrs |> Q.AttrMap.add_no_ns IfaceConfigAttr.is_site_package "True";
      begin match feed_import.os, feed_import.machine with
      | None, None -> ()
      | arch ->
          let arch = Arch.format_arch arch in
          attrs := !attrs |> Q.AttrMap.add_no_ns IfaceConfigAttr.arch arch end;
      Some (ZI.make ~attrs:!attrs "feed")

let save_iface_config config uri iface_config =
  let config_file = Paths.Config.(save_path (interface uri)) config.paths in

  let attrs = ref (Q.AttrMap.singleton FeedAttr.uri uri) in
  iface_config.stability_policy |> if_some (fun policy ->
    attrs := !attrs |> Q.AttrMap.add_no_ns IfaceConfigAttr.stability_policy (Stability.to_string policy)
  );

  let child_nodes = iface_config.extra_feeds |> List.filter_map add_import_elem in
  let root = ZI.make ~attrs:!attrs ~child_nodes "interface-preferences" in

  config_file |> config.system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
    Q.output (`Channel ch |> Xmlm.make_output) root;
  )

let get_cached_feed config = function
  | `Local_feed path -> (
      try
        let root = Q.parse_file config.system path |> Element.parse_feed in
        Some (Feed.parse config.system root (Some path))
      with Safe_exn.T _ as ex ->
        log_warning ~ex "Can't read local file '%s'" path;
        None
  )
  | `Remote_feed url as remote_feed ->
      match get_cached_feed_path config remote_feed with
      | None -> None
      | Some path ->
          let root = Q.parse_file config.system path |> Element.parse_feed in
          let feed = Feed.parse config.system root None in
          if Feed.url feed = remote_feed then Some feed
          else Safe_exn.failf "Incorrect URL in cached feed - expected '%s' but found '%a'" url Feed.pp_url feed

let get_last_check_attempt config url =
  match Paths.Cache.(first (last_check_attempt url)) config.paths with
  | None -> None
  | Some path ->
      match config.system#stat path with
      | None -> None
      | Some info -> Some info.Unix.st_mtime

let internal_is_stale config (`Remote_feed url as feed_url) overrides =
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
      match overrides.Feed_metadata.last_checked with
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
  let overrides = Feed_metadata.load config url in
  internal_is_stale config url (Some overrides)

let mark_as_checking config url =
  let timestamp_path = Paths.Cache.(save_path (last_check_attempt url)) config.paths in
  U.touch config.system timestamp_path
