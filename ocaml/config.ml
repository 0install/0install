(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Configuration settings *)

open General;;

type config = {
  basedirs: Basedir.basedirs;
  stores: string list;
  abspath_0install: filepath;
  freshness: int option;
};;

(** {2 Relative configuration paths (e.g. under ~/.config)} *)

let config_site = "0install.net"
let config_prog = "injector"
let config_injector_interfaces = config_site +/ config_prog +/ "interfaces"
let config_injector_global = config_site +/ config_prog +/ "global"

(** {2 Functions} *)

(** [get_default_config path_to_0install] creates a configuration from the current environment.
    [path_to_0install] is used when creating launcher scripts. If it contains no slashes, then
    we search for it in $PATH.
  *)
let get_default_config path_to_0install =
  let abspath_0install = if String.contains path_to_0install Filename.dir_sep.[0] then
    Support.abspath path_to_0install
  else
    Support.find_in_path_ex path_to_0install
  in

  let basedirs_config = Basedir.get_default_config () in {
    basedirs = basedirs_config;
    stores = Stores.get_default_stores basedirs_config;
    abspath_0install;
    freshness = Some (30 * days);   (* TODO - read from config_injector_global *)
  }
;;

let load_first_config rel_path config =
  Basedir.load_first rel_path config.basedirs.Basedir.config
;;
