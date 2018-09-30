(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Managing cached implementations *)

open Support.Common

type stores = filepath list
type available_digests = (string, filepath) Hashtbl.t   (* Digest -> Parent directory of implementation *)

exception Not_stored of string

val lookup_maybe : #filesystem -> Manifest.digest list -> stores -> filepath option
val lookup_any : #filesystem -> Manifest.digest list -> stores -> string
val get_default_stores : system -> Paths.t -> stores

(** Scan all the stores and build a set of the available digests. This can be used
    later to quickly test whether a digest is in the cache. *)
val get_available_digests : #filesystem -> stores -> available_digests
val check_available : available_digests -> Manifest.digest list -> bool

(* (for parsing <implementation> and <selection> elements) *)
val get_digests : [< `Implementation | `Selection] Element.t -> Manifest.digest list

(* Raises an exception if no digest is supported *)
val best_digest : Manifest.digest list -> Manifest.digest

(** Recursively set permissions:
  * Directories and executable files become 0o555.
  * Other files become 0o444.
  * @raise Safe_exn.T if there are special files or files with special mode bits set *)
val fixup_permissions : #filesystem -> filepath -> unit

(** Create a temporary directory in the directory where we would store a new implementation.
    This is used to set up a new implementation before being renamed if it turns out OK. *)
val make_tmp_dir : #filesystem -> stores -> filepath

val check_manifest_and_rename : General.config -> Manifest.digest -> filepath -> unit Lwt.t
val add_dir_to_cache : General.config -> Manifest.digest -> filepath -> unit Lwt.t
