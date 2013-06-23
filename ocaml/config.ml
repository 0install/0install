(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Configuration settings *)

open Support;;

type config = {
  basedirs: Basedir.basedirs;
  stores: string list;
  abspath_0install: filepath;
};;

(** [get_default_config path_to_0install] creates a configuration from the current environment.
    [path_to_0install] is used when creating launcher scripts. If it contains no slashes, then
    we search for it in $PATH.
  *)
let get_default_config path_to_0install =
  let abspath_0install = if String.contains path_to_0install Filename.dir_sep.[0] then
    abspath path_to_0install
  else
    find_in_path_ex path_to_0install
  in

  let basedirs_config = Basedir.get_default_config () in {
    basedirs = basedirs_config;
    stores = Stores.get_default_stores basedirs_config;
    abspath_0install;
  }
;;
