(* Copyright (C) 2017, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Special-case code for detecting some Python-related packages that used to
    be installed automatically whenever 0install was, but now might not be
    after the move to OCaml. *)

open Support.Common

type t

val make : system -> t

val get : t -> [> `Remote_feed of string] -> (string * [`Package_impl of Impl.package_impl] Impl.t) list
(** [get t feed_url] returns the list of host implementations of [feed_url], if we recognise it. *)
