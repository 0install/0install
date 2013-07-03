(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** XDG Base Directory support, for locating caches, configuration, etc *)

IFDEF WINDOWS THEN
external win_get_appdata : unit -> string = "caml_win_get_appdata";;
external win_get_local_appdata : unit -> string = "caml_win_get_local_appdata";;
external win_get_common_appdata : unit -> string = "caml_win_get_common_appdata";;
ENDIF
 
open Common

let (+/) = Filename.concat

let re_path_sep = Str.regexp_string path_sep;;

type basedirs = {
  data: filepath list;
  cache: filepath list;
  config: filepath list;
};;

let get_path (system:system) home_var dirs_var = function
  | [] -> failwith "No defaults!"
  | (default_home :: default_system) ->

    let user_dir =
      match system#getenv home_var with
      | None -> default_home
      | Some dir -> dir in

    let system_dirs =
      match system#getenv dirs_var with
      | None -> default_system
      | Some path -> List.filter ((<>) "") (Str.split re_path_sep path) in

    user_dir :: system_dirs
;;

let get_unix_home (system:system) =
  let home = default "/root" (system#getenv "HOME") in
  let open Unix in
  if geteuid () <> 0 then (
    home    (* We're not root; no problem *)
  ) else if (stat home).st_uid = 0 then (
    home    (* We're root and $HOME is set correctly *)
  ) else (
    (* We're running as root and $HOME isn't root's home. Try to find
       correct value for root's home, or we're likely to fill the user's
       home directory with unreadable root-owned files. *)
    let root_home =
      try (getpwuid 0).pw_dir
      with Not_found -> "/" in
    Logging.log_info "Running as root, but $HOME (%s) is not owned by root. Using %s instead." home root_home;
    root_home
  )
;;

let get_default_config (system:system) =
  match system#getenv "ZEROINSTALL_PORTABLE_BASE" with
  | Some base ->
      {
        data = [base +/ "data"];
        cache = [base +/ "cache"];
        config = [base +/ "config"];
      }
  | None -> 
      let get = get_path system in
      IFDEF WINDOWS THEN
        let app_data = win_get_appdata () in
        let local_app_data = win_get_local_appdata () in
        let common_app_data = win_get_common_appdata () in
        {
          data = get "XDG_DATA_HOME" "XDG_DATA_DIRS" [app_data; common_app_data];
          cache = get "XDG_CACHE_HOME" "XDG_CACHE_DIRS" [local_app_data; common_app_data];
          config = get "XDG_CONFIG_HOME" "XDG_CONFIG_DIRS" [app_data; common_app_data];
        }
      ELSE
        let home = get_unix_home system in
        {
          data = get "XDG_DATA_HOME" "XDG_DATA_DIRS" [home +/ ".local/share"; "/usr/local/share"; "/usr/share"];
          cache = get "XDG_CACHE_HOME" "XDG_CACHE_DIRS" [home +/ ".cache"; "/var/cache"];
          config = get "XDG_CONFIG_HOME" "XDG_CONFIG_DIRS" [home +/ ".config"; "/etc/xdg"];
        }
      ENDIF
;;

let load_first (system:system) rel_path search_path =
  let rec loop = function
    | [] -> None
    | (x::xs) ->
        let path = x +/ rel_path in
        if system#file_exists path then Some path else loop xs
  in loop search_path
;;

let save_path (system:Common.system) rel_path dirs =
  let save_dir = List.hd dirs in
  let path = save_dir +/ rel_path in
  if not (system#file_exists path) then
    Utils.makedirs system path 0o700
  else ();
  path
;;
