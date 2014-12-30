(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A simple cache for storing key-value pairs on disk. Distributions may wish to use this to record the
    version(s) of each distribution package currently installed. *)

open Support.Common

type package_name = string
type entry = Version.t * Arch.machine option

(* [new cache config ~cache_leaf source] creates a new cache backed by [cache_leaf].
 * Whenever [source] changes, everything in the cache is assumed to be invalid. *)
class cache : General.config -> cache_leaf:string -> filepath ->
  object
    (** Look up an item in the cache.
     * @param if_missing called if given and no entries are found. Whatever it returns is cached. *)
    method get :
      ?if_missing:(package_name -> entry list) ->
      package_name -> entry list * Distro.quick_test option

    (** The cache is being regenerated from scratch. If you want to
     * pre-populate the cache, do it here by calling the provided function once
     * for each entry. Otherwise, you can populate it lazily using [get
     * ~if_missing]. *)
    method private regenerate_cache : (package_name -> entry -> unit) -> unit
  end
