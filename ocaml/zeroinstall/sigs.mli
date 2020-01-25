(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Some useful abstract module types. *)

open Support.Common

type iface_uri = string
(** A URI used to identify an interface.
    Uses only plain URI characters, unicode chars, spaces, etc are %-escaped. *)

type feed_url = string

module type SELECTIONS = Zeroinstall_solver.S.SELECTIONS

module type SEARCH_PATH = sig
  type config
  type key

  val all_paths : key -> config -> filepath list
  (** [all_paths key config] is all configured paths for [key], in search order,
      whether they exist currently or not. *)

  val first : key -> config -> filepath option
  (** [first key config] is the first existing path of [key] in the search path. *)

  val save_path : key -> config -> filepath
  (** [save_path key config] creates a directory for [key] in the first directory in
      the search path (if it doesn't yet exist) and returns the path of the
      [key] within it (which may not yet exist). *)
end
