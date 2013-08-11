(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Provides implementation candidates to the solver. *)

open General
open Support.Common

(** We filter the implementations before handing them to the solver, excluding any
    we know are unsuitable even on their own. *)
type acceptability =
  | Acceptable                (* We can use this version *)
  | User_restriction_rejects  (* Excluded by --version-for or similar *)
  | Poor_stability            (* Buggy/Insecure *)
  | No_retrieval_methods      (* Not cached and no way to get it *)
  | Not_cached_and_offline    (* Can't download it becuase we're offline *)
  | Incompatible_OS           (* Required platform not in os_ranks *)
  | Not_binary                (* We want a binary and this is source *)
  | Not_source                (* We want source and this is a binary *)
  | Incompatible_machine      (* Required CPU not in machine_ranks *)

type scope_filter = {
  extra_restrictions : Feed.restriction StringMap.t;  (* iface -> test *)
  os_ranks : int StringMap.t;
  machine_ranks : int StringMap.t;
}

class type impl_provider =
  object
    (** Return all the implementations of this interface (including from feeds).
        Most preferred implementations should come first. *)
    method get_implementations : scope_filter -> iface_uri -> source:bool -> Feed.implementation list
  end

class default_impl_provider _config distro (feed_provider : Feed_cache.feed_provider) =
  let get_impls feed = Feed.get_implementations feed in

  object (_ : #impl_provider)
    val cache = Hashtbl.create 10

    method get_implementations (scope_filter : scope_filter) iface ~source:want_source =
      let {extra_restrictions; os_ranks; machine_ranks} = scope_filter in

      let get_extra_feeds iface_config =
        let get_feed_if_useful {Feed.feed_src; Feed.feed_os; Feed.feed_machine; Feed.feed_langs; Feed.feed_type = _} =
          ignore feed_langs; (* Maybe later... *)
          (* Don't look at a feed if it only provides things we can't use. *)
          let is_useful =
            (match feed_os with
            | None -> true
            | Some os -> StringMap.mem os os_ranks) &&
            (match feed_machine with
            | None -> true
            | Some machine when want_source -> machine = "src"
            | Some machine -> StringMap.mem machine machine_ranks) in
          if is_useful then feed_provider#get_feed feed_src
          else None
        in
        Support.Utils.filter_map ~f:get_feed_if_useful iface_config.Feed_cache.extra_feeds in

      let passes_user_restrictions =
        try snd (StringMap.find iface extra_restrictions)
        with Not_found ->
          fun _ -> true in

      let impls =
        try Hashtbl.find cache iface
        with Not_found ->
          let master_feed = feed_provider#get_feed iface in
          let iface_config = feed_provider#get_iface_config iface in
          let extra_feeds = get_extra_feeds iface_config in

          (* From master feed, distribution feed, and sub-feeds of master *)
          let main_impls =
            match master_feed with
            | None -> []
            | Some feed ->
                let sub_feeds = [] in         (* TODO: added by master feed *)
                (* TODO: remove feeds for incompatbile architectures *)
                let distro_impls =
                  Distro.get_package_impls distro feed in
                List.concat (distro_impls :: List.map get_impls (feed :: sub_feeds)) in

          let impls = List.concat (main_impls :: List.map get_impls extra_feeds) in
          (* TODO: better sorting *)
          let impls = List.sort (fun a b -> compare b.Feed.parsed_version a.Feed.parsed_version) impls in

          Hashtbl.add cache iface impls;
          impls in

      let os_ok impl =
        match impl.Feed.os with
        | None -> true
        | Some required_os -> StringMap.mem required_os os_ranks in

      let machine_ok impl =
        match impl.Feed.machine with
        | None -> true
        | Some required_machine -> StringMap.mem required_machine machine_ranks in

      let check_acceptability impl =
        let stability = Feed.get_stability impl in      (* TODO: user overrides *)
        let is_source = impl.Feed.machine = Some "src" in

        if not (passes_user_restrictions impl) then User_restriction_rejects
        else if stability <= Buggy then Poor_stability
        (* TODO
        else if (config.network_use = Offline || impl.download_sources = []) && not (Selections.is_available impl) then (
          if impl.download_sources = [] then No_retrieval_methods
          if not (List.exists (fun m -> not m.requires_network)) then Not_cached_and_offline
        )
        *)
        else if not (os_ok impl) then Incompatible_OS
        else if want_source && not is_source then Not_source
        else if not (want_source) && is_source then Not_binary
        else if not want_source && not (machine_ok impl) then Incompatible_machine
        else Acceptable
        in

        let do_filter impl = check_acceptability impl = Acceptable in

        List.filter do_filter impls
  end
