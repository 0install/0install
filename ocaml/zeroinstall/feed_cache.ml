(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Caching downloaded feeds on disk *)

open General
open Support.Common
module Qdom = Support.Qdom
module U = Support.Utils
module Basedir = Support.Basedir

type interface_config = {
  stability_policy : stability_level option;
  extra_feeds : Feed.feed_import list;
}

(* If we started a check within this period, don't start another one *)
let failed_check_delay = float_of_int (1 * hours)

let is_local_feed uri = U.path_is_absolute uri

let parse_feed_url url =
  if U.starts_with url "distribution:" then
    `distribution_feed (U.string_tail url 13)
  else if U.path_is_absolute url then
    `local_feed url
  else
    `remote_feed url

(* For local feeds, returns the absolute path. *)
let get_cached_feed_path config = function
  | `local_feed path -> Some path
  | `remote_feed url ->
      let cache = config.basedirs.Basedir.cache in
      Basedir.load_first config.system (config_site +/ "interfaces" +/ Escape.escape url) cache

let get_save_cache_path config (`remote_feed url) =
  let cache = config.basedirs.Support.Basedir.cache in
  let dir = Support.Basedir.save_path config.system (config_site +/ "interfaces") cache in
  dir +/ Escape.escape url

(** Actually, we list all the cached feeds. Close enough. *)
let list_all_interfaces config =
  let interfaces = ref StringSet.empty in
  let system = config.system in

  let check_leaf leaf =
    if leaf.[0] <> '.' then
      let uri = Escape.unescape leaf in
      interfaces := StringSet.add uri !interfaces in

  let scan_dir path =
    match system#readdir (path +/ config_site +/ "interfaces") with
    | Problem _ -> ()
    | Success files -> Array.iter check_leaf files in

  List.iter scan_dir config.basedirs.Basedir.cache;

  !interfaces

(* Note: this was called "update_user_overrides" in the Python *)
let load_iface_config config uri : interface_config =
  let get_site_feed dir =
    if config.system#file_exists dir then (
      match config.system#readdir dir with
      | Success items ->
          U.filter_map_array items ~f:(fun impl ->
            if U.starts_with impl "." then None
            else (
              let feed = dir +/ impl +/ "0install" +/ "feed.xml" in
              if not (config.system#file_exists feed) then (
                log_warning "Site-local feed %s not found" feed;
                None
              ) else  (
                log_debug "Adding site-local feed '%s'" feed;
                let open Feed in
                Some { feed_src = feed; feed_os = None; feed_machine = None; feed_langs = None; feed_type = Site_packages }
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
          let open Feed in
          [ {feed_src = U.realpath config.system path; feed_os = None; feed_machine = None; feed_langs = None; feed_type = Distro_packages } ]
      in

    (* Local feeds in the data directory (e.g. builds created with 0compile) *)
    let site_feeds =
      let rel_path = data_site_packages +/ (String.concat Filename.dir_sep @@ Escape.escape_interface_uri uri) in
      List.concat @@ List.map (fun dir -> get_site_feed @@ dir +/ rel_path) config.basedirs.Basedir.data in

    let load config_file =
      let root = Qdom.parse_file config.system config_file in
      let stability_policy =
        match ZI.get_attribute_opt "stability-policy" root with
        | None -> None
        | Some s -> Some (Feed.parse_stability s ~from_user:true) in

      (* User-registered feeds (0install add-feed) *)
      let known_site_feeds = List.fold_left (fun map feed -> StringSet.add feed.Feed.feed_src map) StringSet.empty site_feeds in
      let user_feeds =
        ZI.filter_map root ~f:(fun item ->
          match ZI.tag item with
          | Some "feed" -> (
              let feed_src = ZI.get_attribute "src" item in
              (* (note: 0install 1.9..1.12 used a different scheme and the "site-package" attribute;
                 we deliberately use a different attribute name to avoid confusion) *)
              if ZI.get_attribute_opt "is-site-package" item <> None then (
                (* Site packages are detected earlier. This test isn't completely reliable,
                   since older versions will remove the attribute when saving the config
                   (hence the next test). *)
                None
              ) else if StringSet.mem feed_src known_site_feeds then (
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

let get_cached_feed config url =
  match parse_feed_url url with
  | `distribution_feed _ -> failwith url
  | `local_feed path -> (
      try
        let root = Qdom.parse_file config.system path in
        Some (Feed.parse config.system root (Some path))
      with Safe_exception _ as ex ->
        log_warning ~ex "Can't read local file '%s'" path;
        None
  )
  | `remote_feed url as remote_feed ->
      match get_cached_feed_path config remote_feed with
      | None -> None
      | Some path ->
          let root = Qdom.parse_file config.system path in
          let feed = Feed.parse config.system root None in
          if feed.Feed.url = url then Some feed
          else raise_safe "Incorrect URL in cached feed - expected '%s' but found '%s'" url feed.Feed.url

let get_last_check_attempt config uri =
  let open Basedir in
  let rel_path = config_site +/ config_prog +/ "last-check-attempt" +/ Escape.pretty uri in
  match load_first config.system rel_path config.basedirs.cache with
  | None -> None
  | Some path ->
      match config.system#stat path with
      | None -> None
      | Some info -> Some info.Unix.st_mtime

let internal_is_stale config url overrides =
  match parse_feed_url url with
  | `distribution_feed _ -> false             (* Ignore (memory-only) PackageKit feeds *)
  | `local_feed _ -> false                    (* Local feeds are never stale *)
  | `remote_feed url ->
    let now = config.system#time in

    let is_stale () =
      match get_last_check_attempt config url with
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
            | Some threshold when staleness >= (Int64.to_float threshold) -> is_stale ()
            | _ -> false

(** Touch a 'last-check-attempt' timestamp file for this feed.
    This prevents us from repeatedly trying to download a failing feed many
    times in a short period. *)
let mark_as_checking config (`remote_feed url) =
  let timestampts_dir = Basedir.save_path config.system cache_last_check_attempt config.basedirs.Basedir.cache in
  let timestamp_path = timestampts_dir +/ Escape.pretty url in
  U.touch config.system timestamp_path

(** Provides feeds to the [Impl_provider.impl_provider] during a solve. Afterwards, it can be used to
    find out which feeds were used (and therefore may need updating). *)
class feed_provider config distro =
  let cache = ref StringMap.empty in
  let distro_cache = ref StringMap.empty in

  object
    method get_feed url : (Feed.feed * Feed.feed_overrides) option =
      try StringMap.find url !cache
      with Not_found ->
        let result =
          match get_cached_feed config url with
          | Some feed ->
            let overrides = Feed.load_feed_overrides config url in
            Some (feed, overrides)
          | None -> None in
        cache := StringMap.add url result !cache;
        result

    method get_distro_impls feed =
      let url = "distribution:" ^ feed.Feed.url in
      try StringMap.find url !distro_cache
      with Not_found ->
        let result =
          match Distro.get_package_impls distro feed with
          | None -> None
          | Some impls ->
              let overrides = Feed.load_feed_overrides config url in
              Some (impls, overrides) in
        distro_cache := StringMap.add url result !distro_cache;
        result

    method get_iface_config uri =
      load_iface_config config uri

    (* Note: excludes distro feeds *)
    method get_feeds_used =
      StringMap.fold (fun uri _value lst -> uri :: lst) !cache []

    method have_stale_feeds () =
      let check uri = function
        | None -> internal_is_stale config uri None
        | Some (_feed, overrides) -> internal_is_stale config uri (Some overrides) in
      StringMap.exists check !cache

    method replace_feed url new_feed =
      let overrides = Feed.load_feed_overrides config url in
      cache := StringMap.add url (Some (new_feed, overrides)) !cache

    method forget_distro url = distro_cache := StringMap.remove url !distro_cache
  end
