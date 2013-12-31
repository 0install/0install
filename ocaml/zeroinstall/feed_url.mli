(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Feed URLs *)

type non_distro_feed = [`local_feed of Support.Common.filepath | `remote_feed of string]
type parsed_feed_url = [`distribution_feed of non_distro_feed | non_distro_feed ]

(** A globally-unique identifier for an implementation. *)
type global_id = {
  feed : parsed_feed_url;
  id : string;
}

val parse_non_distro : General.feed_url -> non_distro_feed

val parse : General.feed_url -> parsed_feed_url

val format_url : [< parsed_feed_url] -> General.feed_url

(** Get the master feed for an interface URI. Internally, this is just [parse_non_distro]. *)
val master_feed_of_iface : General.iface_uri -> [>non_distro_feed]

module FeedSet : (Set.S with type elt = non_distro_feed)
module FeedMap : (Map.S with type key = non_distro_feed)
