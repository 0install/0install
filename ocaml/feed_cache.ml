(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Caching downloaded feeds on disk *)

open General
open Support.Common

let get_cached_feed_path config uri =
  let cache = config.basedirs.Support.Basedir.cache in
  Support.Basedir.load_first config.system (config_site +/ "interfaces" +/ Escape.escape uri) cache
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
