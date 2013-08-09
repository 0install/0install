(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Provides implementation candidates to the solver. *)

open Support.Common

class impl_provider config distro =
  let get_impls feed = Feed.get_implementations feed in

  let feeds_used = ref StringSet.empty in

  let get_feed url =
    feeds_used := StringSet.add url !feeds_used;
    Feed_cache.get_cached_feed config url in

  object
    val cache = Hashtbl.create 10

    method get_implementations iface =
      try Hashtbl.find cache iface
      with Not_found ->
        let master_feed = get_feed iface in
        let extra_feeds = [] in       (* TODO: added by user *)

        (* From master feed, distribution feed, and sub-feeds of master *)
        let main_impls =
          match master_feed with
          | None -> []
          | Some feed ->
              let sub_feeds = [] in         (* TODO: added by master feed *)
              let distro_impls =
                Distro.get_package_impls distro feed in
              List.concat (distro_impls :: List.map get_impls (feed :: sub_feeds)) in

        let impls = List.concat (main_impls :: List.map get_impls extra_feeds) in
        (* TODO: better sorting *)
        let impls = List.sort (fun a b -> compare b.parsed_version a.parsed_version) impls in

        Hashtbl.add cache iface impls;
        impls

    method get_feeds_used () = !feeds_used
  end
