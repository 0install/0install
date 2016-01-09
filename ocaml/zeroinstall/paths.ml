(* Copyright (C) 2016, Thomas Leonard
 * See the README file for details, or visit http://0install.net. *)

open Support.Common

type t = {
  system : system;
  dirs : Support.Basedir.basedirs;
}

let site = "0install.net"
let prog = "injector"

let get_default system =
  let dirs =
    match system#getenv "ZEROINSTALL_PORTABLE_BASE" with
    | None ->
        let xdg = Support.Basedir.get_default_config system in
        let add_site x = x +/ site in
        { Support.Basedir.
          data = xdg.Support.Basedir.data |> List.map add_site;
          cache = xdg.Support.Basedir.cache |> List.map add_site;
          config = xdg.Support.Basedir.config |> List.map add_site;
        }
    | Some base ->
        { Support.Basedir.
          data = [base +/ "data"];
          cache = [base +/ "cache"];
          config = [base +/ "config"];
        } in
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

module Config = struct
  include Make(struct let paths t = t.dirs.Support.Basedir.config end)

  let injector_interfaces = prog +/ "interfaces"
  let injector_global = prog +/ "global"
  let trust_db = prog +/ "trustdb.xml"
  let apps = "apps"
  let feeds = prog +/ "feeds"
  let user_overrides = prog +/ "user_overrides"
  let implementation_dirs = prog +/ "implementation-dirs"
end

module Data = struct
  include Make(struct let paths t = t.dirs.Support.Basedir.data end)

  let site_packages = "site-packages"
  let native_feeds = "native_feeds"
end

module Cache = struct
  include Make(struct let paths t = t.dirs.Support.Basedir.cache end)

  let last_check_attempt = prog +/ "last-check-attempt"
  let icons = "interface_icons"
  let injector = prog
  let interfaces = "interfaces"
  let implementations = "implementations"

  let in_user_cache path t =
    let cache_home = List.hd t.dirs.Support.Basedir.cache in
    Support.Utils.starts_with path (Filename.concat cache_home "")
end
