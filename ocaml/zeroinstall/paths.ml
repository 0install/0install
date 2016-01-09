(* Copyright (C) 2016, Thomas Leonard
 * See the README file for details, or visit http://0install.net. *)

open Support.Common

type t = {
  system : system;
  dirs : Support.Basedir.basedirs;
}

let get_default system =
  let dirs = Support.Basedir.get_default_config system in
  { system; dirs }

module type Field = sig val paths : t -> filepath list end
module Make (F : Field) = struct
  type config = t
  type key = filepath

  let first key t = Support.Basedir.load_first t.system key (F.paths t)
  let all_paths key t = F.paths t |> List.map (fun f -> f +/ key)
  let save_path key t =
    Support.Basedir.save_path t.system (Filename.dirname key) (F.paths t) +/ Filename.basename key

  let (//) = (+/)
end

let site = "0install.net"
let prog = "injector"

module Config = struct
  include Make(struct let paths t = t.dirs.Support.Basedir.config end)

  let injector_interfaces = site +/ prog +/ "interfaces"
  let injector_global = site +/ prog +/ "global"
  let trust_db = site +/ prog +/ "trustdb.xml"
  let apps = site +/ "apps"
  let feeds = site +/ prog +/ "feeds"
  let user_overrides = site +/ prog +/ "user_overrides"
  let implementation_dirs = site +/ prog +/ "implementation-dirs"
end

module Data = struct
  include Make(struct let paths t = t.dirs.Support.Basedir.data end)

  let site_packages = site +/ "site-packages"
  let native_feeds = site +/ "native_feeds"
end

module Cache = struct
  include Make(struct let paths t = t.dirs.Support.Basedir.cache end)

  let last_check_attempt = site +/ prog +/ "last-check-attempt"
  let icons = site +/ "interface_icons"
  let injector = site +/ prog
  let interfaces = site +/ "interfaces"
  let implementations = site +/ "implementations"

  let in_user_cache path t =
    let cache_home = List.hd t.dirs.Support.Basedir.cache in
    Support.Utils.starts_with path (Filename.concat cache_home "")
end
