(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Managing cached implementations *)

open Support.Common

type stores = filepath list
type digest = string * string
type available_digests

exception Not_stored of string

val format_digest : digest -> string
val lookup_maybe : system -> digest list -> stores -> filepath option
val lookup_any : system -> digest list -> stores -> string
val get_default_stores : Support.Basedir.basedirs -> stores

(** Scan all the stores and build a set of the available digests. This can be used
    later to quickly test whether a digest is in the cache. *)
val get_available_digests : system -> stores -> available_digests
val check_available : available_digests -> digest list -> bool

(* (for parsing <implementation> and <selection> elements) *)
val get_digests : Support.Qdom.element -> digest list

(* Raises an exception if no digest is supported *)
val best_digest : digest list -> digest

(** Create a temporary directory in the directory where we would store a new implementation.
    This is used to set up a new implementation before being renamed if it turns out OK. *)
val make_tmp_dir : system -> stores -> filepath
