(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
open Support.Common
module U = Support.Utils

(** We filter the implementations before handing them to the solver, excluding any
    we know are unsuitable even on their own. *)

type rejection_reason = [
  | `User_restriction_rejects of Impl.restriction
  | `Poor_stability
  | `No_retrieval_methods
  | `Not_cached_and_offline
  | `Missing_local_impl of filepath
  | `Incompatible_OS
  | `Not_binary
  | `Not_source
  | `No_compile_command
  | `Incompatible_machine
]

(* Why did we pick one version over another? *)
type preference_reason =
  | PreferAvailable
  | PreferDistro 
  | PreferID 
  | PreferLang 
  | PreferExisting
  | PreferMachine 
  | PreferNonRoot 
  | PreferOS 
  | PreferStability 
  | PreferVersion 

let describe_problem impl =
  let spf = Printf.sprintf in
  function
  | `User_restriction_rejects r -> "Excluded by user-provided restriction: " ^ r#to_string
  | `Poor_stability           -> spf "Poor stability '%s'" Impl.(Stability.to_string impl.stability)
  | `No_retrieval_methods     -> "No retrieval methods"
  | `Not_cached_and_offline   -> "Can't download it because we're offline"
  | `Incompatible_OS          -> "Not compatible with the requested OS type"
  | `Not_binary               -> "We want a binary and this is source"
  | `Not_source               -> "We want source and this is a binary"
  | `No_compile_command       -> "Missing <command name='compile'>"
  | `Incompatible_machine     -> "Not compatible with the requested CPU type"
  | `Missing_local_impl path  -> spf "Local impl's directory (%s) is missing" path

let describe_preference = function
  | PreferAvailable -> "is locally available"
  | PreferDistro    -> "native packages are preferred"
  | PreferID        -> "better ID (tie-breaker)"
  | PreferLang      -> "natural languages we understand are preferred"
  | PreferExisting  -> "needs to be compiled"
  | PreferMachine   -> "better CPU match"
  | PreferNonRoot   -> "packages that don't require admin access to install are preferred"
  | PreferOS        -> "better OS match"
  | PreferStability -> "more stable versions preferred"
  | PreferVersion   -> "newer versions are preferred"

type candidates = {
  replacement : Sigs.iface_uri option;
  impls : Impl.generic_implementation list;
  rejects : (Impl.generic_implementation * rejection_reason) list;
  compare : Impl.generic_implementation -> Impl.generic_implementation -> int * preference_reason;
  feed_problems : string list;
}

class type impl_provider =
  object
    (** Return all the implementations of this interface (including from feeds).
        Most preferred implementations should come first. *)
    method get_implementations : Sigs.iface_uri -> source:bool -> candidates

    (** Should the solver consider this dependency? *)
    method is_dep_needed : Impl.dependency -> bool

    method extra_restrictions : Impl.restriction StringMap.t
  end

(** Convert a map of impls to a list, applying any overrides to the stability fields. *)
let do_overrides overrides =
  StringMap.map_bindings (fun id impl ->
    match StringMap.find id overrides.Feed.user_stability with
    | Some stability -> Impl.with_stability stability impl
    | None -> impl
  )

let check_acceptability ~scope_filter ~network_use ~is_available ~want_source ~user_restrictions impl =
  let stability = impl.Impl.stability in
  let is_source = Arch.is_src impl.Impl.machine in

  match user_restrictions with
  | Some r when not (r#meets_restriction impl) -> `User_restriction_rejects r
  | _ ->
      if stability <= Stability.Buggy then `Poor_stability
      else if not (Scope_filter.os_ok scope_filter impl.Impl.os) then `Incompatible_OS
      else if want_source && not is_source then `Not_source
      else if not want_source && is_source then `Not_binary
      else if not (Scope_filter.machine_ok scope_filter ~want_source impl.Impl.machine) then `Incompatible_machine
      (* Acceptable if we've got it already or we can get it *)
      else if is_available impl then `Acceptable
      (* It's not cached, but might still be OK... *)
      else (
        let open Impl in
        match (Impl.existing_source impl).impl_type with
        | `Local_impl path -> `Missing_local_impl path
        | `Package_impl _ -> if network_use = Offline then `Not_cached_and_offline else `Acceptable
        | `Cache_impl {retrieval_methods = [];_} -> `No_retrieval_methods
        | `Cache_impl cache_impl ->
            if network_use <> Offline then `Acceptable   (* Can download it *)
            else if is_retrievable_without_network cache_impl then `Acceptable
            else `Not_cached_and_offline
      )

let compare_impls_full ~scope_filter ~network_use ~is_available ~stability_policy a b =
  let retval = ref (0, PreferID) in
  let test reason = function
    | 0 -> false
    | x -> retval := (-x, reason); true in
  let test_fn reason fn =
    test reason @@ compare (fn a) (fn b) in

  let langs_a = Impl.get_langs a in
  let langs_b = Impl.get_langs b in

  let score_true b = if b then 1 else 0 in

  (* 1 if we understand this language, else 0 *)
  let score_langs langs =
    score_true @@ List.exists (Scope_filter.lang_ok scope_filter) langs in

  let score_country langs =
    ListLabels.fold_left ~init:0 langs ~f:(fun best lang ->
      max best (Scope_filter.lang_rank scope_filter lang)
    ) in

  let open Impl in

  let score_os i =
    match i.os with
    | None -> (-100)
    | Some os -> -(default 200 @@ Scope_filter.os_rank scope_filter os) in

  let score_machine i =
    match i.machine with
    | None -> (-100)
    | Some machine -> -(default 200 @@ Scope_filter.machine_rank scope_filter machine) in

  let score_stability i =
    let s = i.stability in
    if s >= stability_policy then Stability.Preferred
    else s in

  let score_is_package i =
    let id = Impl.get_attr_ex "id" i in
    U.starts_with id "package:" in

  let score_requires_root_install i =
    match i.impl_type with
    | `Package_impl {Impl.package_state = `Uninstalled _;_} -> 0   (* Bad - needs root install *)
    | _ -> 1 in

  ignore (
    (* Preferred versions come first *)
    test PreferStability @@ compare (score_true (a.stability = Stability.Preferred))
                                    (score_true (b.stability = Stability.Preferred)) ||

    (* Languages we understand come first *)
    test PreferLang @@ compare (score_langs langs_a) (score_langs langs_b) ||

    (* Prefer available implementations next if we have limited network access *)
    (if network_use = Full_network then false else test_fn PreferAvailable is_available) ||

    (* Packages that require admin access to install come last *)
    test_fn PreferNonRoot score_requires_root_install ||

    (* Prefer more stable versions, but treat everything over stab_policy the same
      (so we prefer stable over testing if the policy is to prefer "stable", otherwise
      we don't care) *)
    test_fn PreferStability score_stability ||

    (* Newer versions come before older ones (ignoring modifiers) *)
    test PreferVersion @@ compare (Version.strip_modifier a.parsed_version)
                                  (Version.strip_modifier b.parsed_version) ||

    (* Prefer native packages if the main part of the versions are the same *)
    test_fn PreferDistro score_is_package ||

    (* Full version compare (after package check, since comparing modifiers between native and non-native
      packages doesn't make sense). *)
    test PreferVersion @@ compare a.parsed_version b.parsed_version ||

    (* Get best OS *)
    test PreferOS @@ compare (score_os a) (score_os b) ||

    (* Prefer an existing binary to one we have to compile. *)
    test_fn PreferExisting (fun impl -> not (Impl.needs_compilation impl)) ||

    (* Get best machine *)
    test PreferMachine @@ compare (score_machine a) (score_machine b) ||

    (* Slightly prefer languages specialised to our country
      (we know a and b have the same base language at this point) *)
    test PreferLang @@ compare (score_country langs_a) (score_country langs_b) ||

    (* Slightly prefer cached versions *)
    (if network_use <> Full_network then false else test_fn PreferAvailable is_available) ||

    (* Order by ID so the order isn't random *)
    test PreferID @@ compare (Impl.get_attr_ex "id" a) (Impl.get_attr_ex "id" b) ||
    test PreferID @@ compare (Impl.get_attr_ex "from-feed" a) (Impl.get_attr_ex "from-feed" b)
  );
  !retval

(** If [impl] is source, convert it to the binary it would produce if compiled, or
 * a close approximation. *)
let src_to_bin ~host_arch ~rejects impl =
  let open Impl in
  if not (is_source impl) then Some (impl :> Impl.generic_implementation)
  else
    match Compiled.of_source ~host_arch impl with
    | `Ok binary -> Some binary
    | `Reject reason -> rejects := ((impl :> Impl.generic_implementation), reason) :: !rejects; None
    | `Filtered_out -> None

class default_impl_provider config (feed_provider : Feed_provider.feed_provider) (scope_filter:Scope_filter.t) =
  let get_distro_impls ~problem feed =
    let {Feed_provider.impls; overrides; problems} = feed_provider#get_distro_impls feed in
    problems |> List.iter problem;
    do_overrides overrides impls in

  let get_impls ~problem (feed, overrides) =
    let distro_impls = (get_distro_impls ~problem feed :> Impl.existing Impl.t list) in
    let zi_impls = (do_overrides overrides feed.Feed.implementations :> Impl.existing Impl.t list) in
    distro_impls @ zi_impls in

  let cached_digests = Stores.get_available_digests config.system config.stores in

  let is_available impl =
    try
      let open Impl in
      match (Impl.existing_source impl).impl_type with
      | `Package_impl {package_state;_} -> package_state = `Installed
      | `Local_impl path -> config.system#file_exists path
      | `Cache_impl {digests;_} -> Stores.check_available cached_digests digests
    with Safe_exception _ as ex ->
      log_warning ~ex "Can't test whether impl is available: %a" Impl.fmt impl;
      false in

  let get_feed_if_useful ~problem want_source feed_import =
    try
      (* Don't look at a feed if it only provides things we can't use. *)
      if Scope_filter.use_feed scope_filter ~want_source feed_import
      then (
        let feed = feed_provider#get_feed feed_import.Feed.feed_src in
        if feed = None then (
          let feed_url = Feed_url.format_url feed_import.Feed.feed_src in
          problem (Printf.sprintf "Imported feed '%s' not available" feed_url)
        );
        feed
      ) else None
    with Safe_exception _ as ex ->
      log_warning ~ex "Failed to get implementations";
      let feed_url = Feed_url.format_url feed_import.Feed.feed_src in
      problem (Printf.sprintf "Error getting imported feed '%s': %s" feed_url (Printexc.to_string ex));
      None
  in

  let get_extra_feeds ~problem want_source iface_config =
    Support.Utils.filter_map (get_feed_if_useful ~problem want_source) iface_config.Feed_cache.extra_feeds in

  let impls_for_iface = U.memoize ~initial_size:10 (fun (iface, want_source) ->
    let master_feed = feed_provider#get_feed (Feed_url.master_feed_of_iface iface) in
    let iface_config = feed_provider#get_iface_config iface in
    let feed_problems = ref [] in
    let problem msg = feed_problems := msg :: !feed_problems in
    let extra_feeds = get_extra_feeds ~problem want_source iface_config in

    (* From master feed, distribution feed, and sub-feeds of master *)
    let (main_impls, stability_policy) =
      match master_feed with
      | None ->
          problem (Printf.sprintf "Main feed '%s' not available" iface);
          ([], None)
      | Some ((feed, _overrides) as pair) ->
          let sub_feeds = U.filter_map (get_feed_if_useful ~problem want_source) feed.Feed.imported_feeds in
          let impls = List.concat (List.map (get_impls ~problem) (pair :: sub_feeds)) in
          (impls, iface_config.Feed_cache.stability_policy) in

    let stability_policy =
      match stability_policy with
      | None -> if config.help_with_testing then Stability.Testing else Stability.Stable
      | Some s -> s in

    let network_use = config.network_use in
    let compare_impls_full = compare_impls_full ~scope_filter ~network_use ~is_available ~stability_policy in
    let compare_impls a b = fst (compare_impls_full a b) in

    let replacement =
      match master_feed with
      | None -> None
      | Some (feed, _overrides) -> feed.Feed.replacement in

    let user_restrictions = Scope_filter.user_restriction_for scope_filter iface in

    let rejects = ref [] in

    let do_filter impl =
      match check_acceptability ~scope_filter ~network_use ~is_available ~want_source ~user_restrictions impl with
      | `Acceptable -> true
      | #rejection_reason as x -> rejects := (impl, x) :: !rejects; false
    (*| problem -> log_warning "rejecting %s %s: %s" iface (Version.format_version impl.Impl.parsed_version) (describe_problem impl problem); false *)
    in

    let map_potential_binaries existing_impls =
      if scope_filter.Scope_filter.may_compile && not want_source then (
        let (host_os, host_machine) = Arch.platform config.system in
        let host_arch = (Some host_os, Some host_machine) in
        U.filter_map (src_to_bin ~host_arch ~rejects) existing_impls
      ) else (
        (existing_impls :> Impl.generic_implementation list)
      ) in

    let impls =
      List.concat (main_impls :: List.map (get_impls ~problem) extra_feeds)
      |> map_potential_binaries
      |> List.sort compare_impls
      |> List.filter do_filter in

    {replacement; impls; rejects = !rejects; compare = compare_impls_full; feed_problems = !feed_problems}
  ) in

  object (_ : #impl_provider)
    method is_dep_needed dep =
      Scope_filter.use_ok scope_filter dep.Impl.dep_use &&
      Scope_filter.os_ok scope_filter dep.Impl.dep_if_os

    method extra_restrictions = scope_filter.Scope_filter.extra_restrictions

    method get_implementations iface ~source:want_source =
      impls_for_iface (iface, want_source)
  end
