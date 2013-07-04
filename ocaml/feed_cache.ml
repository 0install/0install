(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Caching downloaded feeds on disk *)

open General
open Support.Common
module Qdom = Support.Qdom

type interface_config = {
  stability_policy : stability_level option;
  extra_feeds : Qdom.element list;
}

(* For local feeds, returns the absolute path. *)
let get_cached_feed_path config uri =
  if Support.Utils.path_is_absolute uri then (
    Some uri
  ) else (
    let cache = config.basedirs.Support.Basedir.cache in
    Support.Basedir.load_first config.system (config_site +/ "interfaces" +/ Escape.escape uri) cache
  )
;;

(** Actually, we list all the cached feeds. Close enough. *)
let list_all_interfaces config =
  let interfaces = ref StringSet.empty in
  let system = config.system in
  let module Basedir = Support.Basedir in

  let check_leaf leaf =
    if leaf.[0] <> '.' then
      let uri = Escape.unescape leaf in
      interfaces := StringSet.add uri !interfaces in

  let scan_dir path =
    match system#readdir (path +/ config_site +/ "interfaces") with
    | Failure _ -> ()
    | Success files -> Array.iter check_leaf files in

  List.iter scan_dir config.basedirs.Basedir.cache;

  !interfaces

let parse_stability = function
  | "preferred" -> Preferred
  | "packaged" -> Packaged
  | "stable" -> Stable
  | "testing" -> Testing
  | "developer" -> Developer
  | "buggy" -> Buggy
  | "insecure" -> Insecure
  | x -> raise_safe "Invalid stability level '%s'" x

let load_iface_config config uri =
  try
    match Config.load_first_config (config_injector_interfaces +/ Escape.pretty uri) config with
    | None -> { stability_policy = None; extra_feeds = [] }
    | Some config_file ->
        let root = Qdom.parse_file config.system config_file in
        let stability_policy = match ZI.get_attribute_opt "stability-policy" root with
        | None -> None
        | Some p -> Some (parse_stability p) in
        let extra_feeds = ZI.filter_map root "feed" ~f:(function feed ->
          (* note: 0install 1.9..1.12 used a different scheme and the "site-package" attribute;
             we deliberately use a different attribute name to avoid confusion) *)
          if ZI.get_attribute_opt "is-site-package" feed <> None then (
              (* Site packages are detected earlier. This test isn't completely reliable,
                since older versions will remove the attribute when saving the config
                (hence the next test). *)
              None
          ) else if false then (
            (* TODO: known_site_feeds *)
            None
          ) else (
            Some feed
          )
        ) in
        { stability_policy; extra_feeds }
  with Safe_exception _ as ex -> reraise_with_context ex "... reading configuration settings for interface %s" uri

let get_cached_feed config uri =
  (* TODO:  local feeds *)
  match get_cached_feed_path config uri with
  | None -> None
  | Some path ->
      let root = Qdom.parse_file config.system path in
      Some (Feed.parse root)
