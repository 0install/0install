(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Caching feeds in memory *)

module U = Support.Utils
module Basedir = Support.Basedir
module FeedMap = Feed_url.FeedMap

(** Provides feeds to the [Impl_provider.impl_provider] during a solve. Afterwards, it can be used to
    find out which feeds were used (and therefore may need updating). *)
class feed_provider config distro =
  object (self : #Feed_provider.feed_provider)
    val mutable cache = FeedMap.empty
    val mutable distro_cache : Feed_provider.distro_impls FeedMap.t = FeedMap.empty

    method get_feed url : (Feed.feed * Feed.feed_overrides) option =
      try FeedMap.find url cache
      with Not_found ->
        let result =
          match Feed_cache.get_cached_feed config url with
          | Some feed ->
            let overrides = Feed.load_feed_overrides config url in
            Some (feed, overrides)
          | None -> None in
        cache <- FeedMap.add url result cache;
        result

    method get_distro_impls feed =
      let master_feed_url = feed.Feed.url in
      let url = `Distribution_feed master_feed_url in
      try FeedMap.find master_feed_url distro_cache
      with Not_found ->
        let problems = ref [] in
        let problem msg = problems := msg :: !problems in
        let result =
          let impls = Distro.get_impls_for_feed distro ~problem feed in
          let overrides = Feed.load_feed_overrides config url in
          {Feed_provider.impls; overrides; problems = !problems} in
        distro_cache <- FeedMap.add master_feed_url result distro_cache;
        result

    method get_iface_config uri =
      Feed_cache.load_iface_config config uri

    (* Note: excludes distro feeds *)
    method get_feeds_used =
      FeedMap.fold (fun uri _value lst -> uri :: lst) cache []

    method was_used feed = FeedMap.mem feed cache

    method have_stale_feeds =
      let check url info =
        match url, info with
        | `Local_feed _, _ -> false
        | `Remote_feed _ as url, None -> Feed_cache.internal_is_stale config url None
        | `Remote_feed _ as url, Some (_feed, overrides) -> Feed_cache.internal_is_stale config url (Some overrides) in
      FeedMap.exists check cache

    method replace_feed url new_feed =
      let overrides = Feed.load_feed_overrides config url in
      cache <- FeedMap.add url (Some (new_feed, overrides)) cache

    method forget_distro url = distro_cache <- FeedMap.remove url distro_cache

    (* Used after compiling a new version. *)
    method forget_user_feeds iface =
      let iface_config = self#get_iface_config iface in
      iface_config.Feed_cache.extra_feeds |> List.iter (fun {Feed.feed_src; _} ->
        cache <- FeedMap.remove feed_src cache
      )
  end
