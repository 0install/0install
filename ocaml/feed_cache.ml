(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Caching downloaded feeds on disk *)

open Support
open Config

let get_cached_feed_path uri config =
  let cache = config.Config.basedirs.Basedir.cache in
  Basedir.load_first (config_site +/ "interfaces" +/ Escape.escape uri) cache
;;
