(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Caching feeds in memory *)

open Support.Common
module Q = Support.Qdom
module U = Support.Utils
module Basedir = Support.Basedir

(** Provides feeds to the [Impl_provider.impl_provider] during a solve. Afterwards, it can be used to
    find out which feeds were used (and therefore may need updating). *)
class feed_provider config distro =
  let cache = ref StringMap.empty in
  let distro_cache = ref StringMap.empty in

  object
    method get_feed url : (Feed.feed * Feed.feed_overrides) option =
      try StringMap.find url !cache
      with Not_found ->
        let result =
          match Feed_cache.get_cached_feed config url with
          | Some feed ->
            let overrides = Feed.load_feed_overrides config url in
            Some (feed, overrides)
          | None -> None in
        cache := StringMap.add url result !cache;
        result

    method get_distro_impls feed =
      let url = "distribution:" ^ feed.Feed.url in
      try StringMap.find url !distro_cache
      with Not_found ->
        let result =
          match Distro.get_package_impls distro feed with
          | None -> None
          | Some impls ->
              let overrides = Feed.load_feed_overrides config url in
              Some (impls, overrides) in
        distro_cache := StringMap.add url result !distro_cache;
        result

    method get_iface_config uri =
      Feed_cache.load_iface_config config uri

    (* Note: excludes distro feeds *)
    method get_feeds_used =
      StringMap.fold (fun uri _value lst -> uri :: lst) !cache []

    method have_stale_feeds =
      let check uri = function
        | None -> Feed_cache.internal_is_stale config uri None
        | Some (_feed, overrides) -> Feed_cache.internal_is_stale config uri (Some overrides) in
      StringMap.exists check !cache

    method replace_feed url new_feed =
      let overrides = Feed.load_feed_overrides config url in
      cache := StringMap.add url (Some (new_feed, overrides)) !cache

    method forget_distro url = distro_cache := StringMap.remove url !distro_cache
  end
