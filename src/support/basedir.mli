(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** XDG Base Directory support, for locating caches, configuration, etc *)

open Common

type basedirs = {
  data: filepath list;
  cache: filepath list;
  config: filepath list;
}

(** Get configuration using [ZEROINSTALL_PORTABLE_BASE] (if set), or the platform default,
 * modified by any [XDG_*] variables which are set. *)
val get_default_config : #system -> basedirs

(** [load_first system relpath search_path] returns the first configuration path (base +/ relpath) that exists
 * from the base paths in [search_path]. *)
val load_first : #filesystem -> filepath -> filepath list -> filepath option

(** [save_path system relpath search_path] creates the directory [List.hd search_path +/ relpath] (and
 * any missing parents) and returns its path. *)
val save_path : #filesystem -> filepath -> filepath list -> filepath

(** Get the home directory (normally [$HOME]). If we're running as root and $HOME isn't owned by root
 * (e.g. under sudo) then return root's real home directory instead. *)
val get_unix_home : system -> filepath
