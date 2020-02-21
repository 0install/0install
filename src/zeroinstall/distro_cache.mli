(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A simple cache for storing key-value pairs on disk. Distributions may wish to use this to record the
    version(s) of each distribution package currently installed. *)

open Support.Common

type t

type package_name = string
type entry = Version.t * Arch.machine option

val create_eager : General.config -> cache_leaf:string -> source:filepath -> regenerate:((package_name -> entry -> unit) -> unit) -> t
(* [create_eager config ~cache_leaf ~source ~regenerate] creates a new cache backed by [cache_leaf].
   Whenever [source] changes, everything in the cache is assumed to be invalid and [regenerate]
   is called. It should call the provided function once for each entry. *)

val create_lazy : General.config -> cache_leaf:string -> source:filepath -> if_missing:(package_name -> entry list) -> t
(** Similar to [create_eager], but the cache is repopulated lazily by calling [if_missing] for a single package
   when it is requested and not present. *)

val get : t -> package_name -> entry list * Distro.quick_test option
(** Look up an item in the cache. *)
