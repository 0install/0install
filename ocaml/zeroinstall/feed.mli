(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing feeds *)

open Support
open Support.Common

type t

val parse : #filesystem -> [`Feed] Element.t -> filepath option -> t

val default_attrs : url:string -> Support.Qdom.AttrMap.t
val process_group_properties : local_dir:filepath option -> Impl.properties ->
  [<`Group | `Implementation | `Package_impl] Element.t -> Impl.properties

val url : t -> Feed_url.non_distro_feed
val name : t -> string
val get_summary : int Support.Locale.LangMap.t -> t -> string option
val get_description : int Support.Locale.LangMap.t -> t -> string option
val imported_feeds : t -> Feed_import.t list
val zi_implementations : t -> [> `Cache_impl of Impl.cache_impl | `Local_impl of filepath] Impl.t XString.Map.t
val package_implementations : t -> ([`Package_impl] Element.t * Impl.properties) list

(** The <feed-for> elements' interfaces *)
val get_feed_targets : t -> Sigs.iface_uri list

val get_category : t -> string option
val needs_terminal : t -> bool
val icons : t -> [`Icon] Element.t list

val replacement : t -> Sigs.iface_uri option
(** The URI of the interface that replaced the one with the URI of this feed's URL.
    This is the value of the feed's <replaced-by interface'...'/> element. *)

val root : t -> [`Feed] Element.t
val pp_url : Format.formatter -> t -> unit
