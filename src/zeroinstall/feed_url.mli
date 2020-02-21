(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Feed URLs *)

type local_feed = [`Local_feed of Support.Common.filepath]
type remote_feed = [`Remote_feed of string]
type non_distro_feed = [local_feed | remote_feed]
type parsed_feed_url = [`Distribution_feed of non_distro_feed | non_distro_feed]

(** A globally-unique identifier for an implementation. *)
type global_id = {
  feed : parsed_feed_url;
  id : string;
}

val parse_non_distro : Sigs.feed_url -> non_distro_feed

val parse : Sigs.feed_url -> parsed_feed_url

val format_url : [< parsed_feed_url] -> Sigs.feed_url

val pp : Format.formatter -> [< parsed_feed_url] -> unit

(** Get the master feed for an interface URI. Internally, this is just [parse_non_distro]. *)
val master_feed_of_iface : Sigs.iface_uri -> [> non_distro_feed]

module FeedSet : (Set.S with type elt = non_distro_feed)
module FeedMap : (Map.S with type key = non_distro_feed)
