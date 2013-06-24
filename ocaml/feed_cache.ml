(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Caching downloaded feeds on disk *)

open General

let get_cached_feed_path config uri =
  let cache = config.basedirs.Basedir.cache in
  Basedir.load_first (Config.config_site +/ "interfaces" +/ Escape.escape uri) cache
;;

let get_feed config uri =
  match get_cached_feed_path config uri with
  | None -> None
  | Some path -> Some (Qdom.parse_file path)
;;
