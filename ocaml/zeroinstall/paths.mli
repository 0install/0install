(* Copyright (C) 2016, Thomas Leonard
 * See the README file for details, or visit http://0install.net. *)

(** Type-safe wrapper for [Support.Basedir] *)

open Support.Common

type t

val get_default : system -> t

module Config : sig
  include Sigs.SEARCH_PATH with type config = t
  val injector_interfaces : key
  val injector_global : key
  val trust_db : key
  val apps : key
  val feeds : key
  val user_overrides : key
  val implementation_dirs : key
end

module Data : sig
  include Sigs.SEARCH_PATH with type config = t

  val site_packages : key   (** 0compile builds, etc *)

  val native_feeds : key    (** Feeds provided by distribution packages (rare) *)
end

module Cache : sig
  include Sigs.SEARCH_PATH with type config = t
  val last_check_attempt : key
  val icons : key
  val injector : key
  val interfaces : key
  val implementations : key

  val in_user_cache : filepath -> t -> bool
  (** [in_user_cache path t] is [true] iff [path] starts with the user cache directory path. *)
end
