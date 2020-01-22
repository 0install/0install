(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing feeds *)

open Support
open Support.Common

(** {2 Types} **)

type feed_overrides = {
  last_checked : float option;
  user_stability : Stability.t XString.Map.t;
}

type feed_type =
  | Feed_import             (* A <feed> import element inside a feed *)
  | User_registered         (* Added manually with "0install add-feed" : save to config *)
  | Site_packages           (* Found in the site-packages directory : save to config for older versions, but flag it *)
  | Distro_packages         (* Found in native_feeds : don't save *)

type feed_import = {
  feed_src : Feed_url.non_distro_feed;

  feed_os : Arch.os option;           (* All impls requires this OS *)
  feed_machine : Arch.machine option; (* All impls requires this CPU *)
  feed_langs : string list option;    (* No impls for languages not listed *)
  feed_type : feed_type;
}

type t

(** {2 Parsing} *)
val parse : #filesystem -> [`Feed] Element.t -> filepath option -> t

val default_attrs : url:string -> Support.Qdom.AttrMap.t
val process_group_properties : local_dir:filepath option -> Impl.properties ->
  [<`Group | `Implementation | `Package_impl] Element.t -> Impl.properties

val load_feed_overrides : General.config -> [< Feed_url.parsed_feed_url] -> feed_overrides
val save_feed_overrides : General.config -> [< Feed_url.parsed_feed_url] -> feed_overrides -> unit
val update_last_checked_time : General.config -> [< Feed_url.remote_feed] -> unit

val url : t -> Feed_url.non_distro_feed
val name : t -> string
val get_summary : int Support.Locale.LangMap.t -> t -> string option
val get_description : int Support.Locale.LangMap.t -> t -> string option
val imported_feeds : t -> feed_import list
val zi_implementations : t -> [> `Cache_impl of Impl.cache_impl | `Local_impl of filepath] Impl.t XString.Map.t
val package_implementations : t -> ([`Package_impl] Element.t * Impl.properties) list

(** The <feed-for> elements' interfaces *)
val get_feed_targets : t -> Sigs.iface_uri list
val make_user_import : [< Feed_url.non_distro_feed] -> feed_import

val get_category : t -> string option
val needs_terminal : t -> bool
val icons : t -> [`Icon] Element.t list

val replacement : t -> Sigs.iface_uri option
(** The URI of the interface that replaced the one with the URI of this feed's URL.
    This is the value of the feed's <replaced-by interface'...'/> element. *)

val root : t -> [`Feed] Element.t
val pp_url : Format.formatter -> t -> unit
