(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Caching downloaded feeds on disk *)

open General
open Support
open Support.Common

type interface_config = {
  stability_policy : Stability.t option;      (* Overrides config.help_with_testing if set *)
  extra_feeds : Feed_import.t list;           (* Feeds added manually with "0install add-feed" *)
}

(** Load a cached feed.
 * As a convenience, this will also load local feeds. *)
val get_cached_feed : config -> [< Feed_url.non_distro_feed] -> Feed.t option
val get_cached_feed_path : config -> Feed_url.remote_feed -> filepath option
val get_save_cache_path : config -> Feed_url.remote_feed -> filepath

val get_cached_icon_path : config -> [< Feed_url.non_distro_feed] -> filepath option

val list_all_feeds : config -> XString.Set.t

val load_iface_config : config -> Sigs.iface_uri -> interface_config
val save_iface_config : config -> Sigs.iface_uri -> interface_config -> unit

(** Check whether feed [url] is stale.
 * Returns false if it's stale but last-check-attempt is recent *)
val is_stale : config -> Feed_url.remote_feed -> bool

(** Low-level part of [is_stale] that doesn't automatically load the feed overrides (needed to get [last_checked]).
 * Useful if you've already loaded them yourself (or confirmed they're missing) to avoid doing it twice. *)
val internal_is_stale : config -> Feed_url.remote_feed -> Feed_metadata.t option -> bool

(** Touch a 'last-check-attempt' timestamp file for this feed.
    This prevents us from repeatedly trying to download a failing feed many
    times in a short period. *)
val mark_as_checking : config -> Feed_url.remote_feed -> unit

val get_last_check_attempt : config -> Feed_url.remote_feed -> float option
