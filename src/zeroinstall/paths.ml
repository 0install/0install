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
end

module Config = struct
  include Make(struct let paths t = t.dirs.Support.Basedir.config end)

  let interface uri = prog +/ "interfaces" +/ Escape.pretty uri
  let global = prog +/ "global"
  let trust_db = prog +/ "trustdb.xml"
  let apps = "apps"
  let app name = apps +/ name
  let feed url = prog +/ "feeds" +/ Escape.pretty (Feed_url.format_url url)
  let user_overrides uri = prog +/ "user_overrides" +/ Escape.escape uri
  let implementation_dirs = prog +/ "implementation-dirs"
end

module Data = struct
  include Make(struct let paths t = t.dirs.Support.Basedir.data end)

  let site_packages uri = "site-packages" +/ String.concat Filename.dir_sep (Escape.escape_interface_uri uri)
  let native_feed uri = "native_feeds" +/ Escape.pretty uri
end

module Cache = struct
  include Make(struct let paths t = t.dirs.Support.Basedir.cache end)

  let last_check_attempt (`Remote_feed url) = prog +/ "last-check-attempt" +/ Escape.pretty url
  let icon feed =
    let (`Remote_feed url | `Local_feed url) = feed in
    "interface_icons" +/ Escape.escape url
  let distro_cache name = prog +/ name
  let named_runner ~hash name = prog +/ "exec-" ^ hash +/ name
  let feeds = "interfaces"
  let feed (`Remote_feed url) = "interfaces" +/ Escape.escape url
  let implementations = "implementations"

  let in_user_cache path t =
    let cache_home = List.hd t.dirs.Support.Basedir.cache in
    Support.XString.starts_with path (Filename.concat cache_home "")
end
