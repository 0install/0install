(* Copyright (C) 2016, Thomas Leonard
 * See the README file for details, or visit http://0install.net. *)

(** Type-safe wrapper for [Support.Basedir] *)

open Support.Common

type t

val get_default : system -> t

module Config : sig
  include Sigs.SEARCH_PATH with type config = t

  val interface : Sigs.iface_uri -> key
  (** [interface uri] is the path of the configuration for interface [uri]. *)

  val user_overrides : Sigs.iface_uri -> key
  (** [user_overrides iface] is the old and deprecated configuration for interface [iface]. *)

  val global : key
  val trust_db : key

  val apps : key
  (** [apps] is a directory containing applications as subdirectories. *)

  val app : string -> key
  (** [app name] is the directory of application [name]. *)

  val feed : [< Feed_url.parsed_feed_url ] -> key
  (** [feed url] is the configuration for the feed at [url]. *)

  val implementation_dirs : key
end

module Data : sig
  include Sigs.SEARCH_PATH with type config = t

  val site_packages : Sigs.iface_uri -> key
  (** [site_packages uri] contains the 0compile builds of interface [uri]. *)

  val native_feed : Sigs.iface_uri -> key
  (** [native_feed iface] is an extra feed for [iface] provided by a distribution package. *)
end

module Cache : sig
  include Sigs.SEARCH_PATH with type config = t
  val last_check_attempt : Feed_url.remote_feed -> key
  val icon : [< Feed_url.non_distro_feed] -> key

  val distro_cache : string -> key
  (** [distro_cache name] is a path which can be used to cache the packages available in the
      distribution package manager (named [name]). *)

  val named_runner : hash:string -> string -> key
  (** [named_runner ~hash name] is a path for an executable named [name] whose contents will have
      the given hash. *)

  val feeds : key
  (** [feeds] is the directory containing the cached feeds. *)

  val feed : Feed_url.remote_feed -> key
  (** [feed url] is the cached copy of [url]. *)

  val implementations : key

  val in_user_cache : filepath -> t -> bool
  (** [in_user_cache path t] is [true] iff [path] starts with the user cache directory path. *)
end
