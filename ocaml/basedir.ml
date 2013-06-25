(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** XDG Base Directory support, for locating caches, configuration, etc *)

open Support;;

(* TODO: ZEROINSTALL_PORTABLE_BASE *)

(* TODO: Windows *)

let re_path_sep = Str.regexp_string path_sep;;

type basedirs = {
  data: filepath list;
  cache: filepath list;
  config: filepath list;
};;

let get_path home_var dirs_var = function
  | [] -> failwith "No defaults!"
  | (default_home :: default_system) ->
    let user_dir =
      try Sys.getenv home_var
      with Not_found -> default_home in
    let system_dirs =
      try List.filter (fun x -> x <> "") (Str.split re_path_sep (Sys.getenv dirs_var))
      with Not_found -> default_system in
    user_dir :: system_dirs
;;

let get_unix_home () =
  let open Unix in
  let home = try Sys.getenv "HOME" with Not_found -> "/" in
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

let get_default_config () =
  if on_windows then
    failwith "Windows"
  else
    let home = get_unix_home () in
    {
      data = get_path "XDG_DATA_HOME" "XDG_DATA_DIRS" [home +/ ".local/share"; "/usr/local/share"; "/usr/share"];
      cache = get_path "XDG_CACHE_HOME" "XDG_CACHE_DIRS" [home +/ ".cache"; "/var/cache"];
      config = get_path "XDG_CONFIG_HOME" "XDG_CONFIG_DIRS" [home +/ ".config"; "/etc/xdg"];
    }
;;

let load_first rel_path search_path =
  let rec loop = function
    | [] -> None
    | (x::xs) ->
        let path = x +/ rel_path in
        if Sys.file_exists path then Some path else loop xs
  in loop search_path
;;

let save_path rel_path dirs =
  let save_dir = List.hd dirs in
  let path = save_dir +/ rel_path in
  if not (Sys.file_exists path) then
    makedirs path 0o700
  else ();
  path
;;
