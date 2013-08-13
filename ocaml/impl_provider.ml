(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Provides implementation candidates to the solver. *)

open General
open Support.Common
module U = Support.Utils

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
  languages : Locale.lang_spec list;    (* Must match one of these, earlier ones preferred *)
}

type candidates = {
  replacement : iface_uri option;
  impls : Feed.implementation list;
}

class type impl_provider =
  object
    (** Return all the implementations of this interface (including from feeds).
        Most preferred implementations should come first. *)
    method get_implementations : scope_filter -> iface_uri -> source:bool -> candidates
  end

class default_impl_provider config distro (feed_provider : Feed_cache.feed_provider) =
  let get_impls (feed, overrides) =
    let do_override impl =
      let id = Feed.get_attr "id" impl in
      try {impl with Feed.stability = StringMap.find id overrides.Feed.user_stability}
      with Not_found -> impl in
    List.map do_override @@ Feed.get_implementations feed
  in

  object (_ : #impl_provider)
    val cache = Hashtbl.create 10

    method get_implementations (scope_filter : scope_filter) iface ~source:want_source =
      let {extra_restrictions; os_ranks; machine_ranks; languages = wanted_langs} = scope_filter in

      let get_feed_if_useful {Feed.feed_src; Feed.feed_os; Feed.feed_machine; Feed.feed_langs; Feed.feed_type = _} =
        try
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
        with Safe_exception _ as ex ->
          log_warning ~ex "Failed to get implementations";
          None
      in

      let get_extra_feeds iface_config =
        Support.Utils.filter_map ~f:get_feed_if_useful iface_config.Feed_cache.extra_feeds in

      let passes_user_restrictions =
        try snd (StringMap.find iface extra_restrictions)
        with Not_found ->
          fun _ -> true in

      let is_available impl =
        try Feed.is_available_locally config distro impl
        with Safe_exception _ as ex ->
          log_warning ~ex "Can't test whether impl is available: %s" (Support.Qdom.show_with_loc impl.Feed.qdom);
          false in

      (* Printf.eprintf "Looking for %s\n" (String.concat "," @@ List.map Locale.format_lang wanted_langs); *)
      let compare_impls stability_policy a b =
        let retval = ref 0 in
        let test = function
          | 0 -> false
          | x -> retval := x; true in
        let test_fn fn =
          test @@ compare (fn a) (fn b) in

        let langs_a = Feed.get_langs a in
        let langs_b = Feed.get_langs b in

        let score_true b = if b then 1 else 0 in

        (* 1 if we understand this language, else 0 *)
        let score_langs langs =
          let is_acceptable (lang, _country) = List.exists (fun (l, _c) -> l = lang) wanted_langs in
          score_true @@ List.exists is_acceptable langs in

        let score_country langs =
          let is_acceptable got = List.mem got wanted_langs in
          score_true @@ List.exists is_acceptable langs in

        let open Feed in

        let score_os i =
          match i.os with
          | None -> (-100)
          | Some os ->
            try -(StringMap.find os os_ranks)
            with Not_found -> (-200) in

        let score_machine i =
          match i.machine with
          | None -> (-100)
          | Some machine ->
            try -(StringMap.find machine machine_ranks)
            with Not_found -> (-200) in

        let score_stability i =
          let s = i.stability in
          if s >= stability_policy then Preferred
          else s in

        let score_is_package i =
          let id = Feed.get_attr "id" i in
          U.starts_with id "package:" in

        let score_requires_root_install i =
          if i.impl_type = PackageImpl then score_true @@ is_available i
          else 1 in

        ignore (
          (* Preferred versions come first *)
          test @@ compare (score_true (a.stability = Preferred))
                          (score_true (b.stability = Preferred)) ||

          (* Languages we understand come first *)
          test @@ compare (score_langs langs_a) (score_langs langs_b) ||

          (* Prefer available implementations next if we have limited network access *)
          (if config.network_use = Full_network then false else test_fn is_available) ||

          (* Packages that require admin access to install come last *)
          test_fn score_requires_root_install ||

          (* Prefer more stable versions, but treat everything over stab_policy the same
            (so we prefer stable over testing if the policy is to prefer "stable", otherwise
            we don't care) *)
          test_fn score_stability ||

          (* Newer versions come before older ones (ignoring modifiers) *)
          test @@ compare (Versions.strip_modifier a.parsed_version)
                          (Versions.strip_modifier b.parsed_version) ||

          (* Prefer native packages if the main part of the versions are the same *)
          test_fn score_is_package ||

          (* Full version compare (after package check, since comparing modifiers between native and non-native
            packages doesn't make sense). *)
          test @@ compare a.parsed_version b.parsed_version ||

          (* Get best OS *)
          test @@ compare (score_os a) (score_os b) ||

          (* Get best machine *)
          test @@ compare (score_machine a) (score_machine b) ||

          (* Slightly prefer languages specialised to our country
            (we know a and b have the same base language at this point) *)
          test @@ compare (score_country langs_a) (score_country langs_b) ||

          (* Slightly prefer cached versions *)
          (if config.network_use <> Full_network then false else test_fn is_available) ||

          (* Order by ID so the order isn't random *)
          test @@ compare (Feed.get_attr "id" a) (Feed.get_attr "id" b)
        );

        -(!retval)
        in

      let candidates : candidates =
        try Hashtbl.find cache iface
        with Not_found ->
          let master_feed = feed_provider#get_feed iface in
          let iface_config = feed_provider#get_iface_config iface in
          let extra_feeds = get_extra_feeds iface_config in

          (* From master feed, distribution feed, and sub-feeds of master *)
          let (main_impls, stability_policy) =
            match master_feed with
            | None -> ([], None)
            | Some ((feed, _overrides) as pair) ->
                let sub_feeds = U.filter_map ~f:get_feed_if_useful feed.Feed.imported_feeds in
                (* TODO: remove feeds for incompatbile architectures *)
                let distro_impls =
                  Distro.get_package_impls distro feed in
                (* TODO: overrides for distro_impls *)
                let impls = List.concat (distro_impls :: List.map get_impls (pair :: sub_feeds)) in
                (impls, iface_config.Feed_cache.stability_policy) in

          let stability_policy =
            match stability_policy with
            | None -> if config.help_with_testing then Testing else Stable
            | Some s -> s in

          let impls = List.sort (compare_impls stability_policy) @@ List.concat (main_impls :: List.map get_impls extra_feeds) in

          let replacement =
            match master_feed with
            | None -> None
            | Some (feed, _overrides) -> feed.Feed.replacement in

          let candidates = {replacement; impls} in
          Hashtbl.add cache iface candidates;
          candidates in

      let os_ok impl =
        match impl.Feed.os with
        | None -> true
        | Some required_os -> StringMap.mem required_os os_ranks in

      let machine_ok impl =
        match impl.Feed.machine with
        | None -> true
        | Some required_machine -> StringMap.mem required_machine machine_ranks in

      let check_acceptability impl =
        let stability = Feed.get_stability impl in
        let is_source = impl.Feed.machine = Some "src" in

        if not (passes_user_restrictions impl) then User_restriction_rejects
        else if stability <= Buggy then Poor_stability
        else if not (os_ok impl) then Incompatible_OS
        else if want_source && not is_source then Not_source
        else if not (want_source) && is_source then Not_binary
        else if not want_source && not (machine_ok impl) then Incompatible_machine
        else if is_available impl then Acceptable
        (* It's not cached, but might still be OK... *)
        else if impl.Feed.impl_type = Feed.PackageImpl then (
          if config.network_use <> Offline then Acceptable else Not_cached_and_offline
        ) else (
          (* Non-distro-package is not cached *)
          let methods = Recipe.get_retrieval_methods impl in
          if methods = [] then No_retrieval_methods
          else if config.network_use <> Offline then Acceptable   (* Can downlad it *)
          else if List.exists (fun r -> not (Recipe.recipe_requires_network r)) methods then
            Acceptable        (* Offline and not cached, but we can get it without using the network *)
          else
            Not_cached_and_offline
        ) in

      let do_filter impl = check_acceptability impl = Acceptable in

      {candidates with impls = List.filter do_filter (candidates.impls)}
  end
