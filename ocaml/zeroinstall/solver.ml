(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Select a compatible set of components to run a program. *)

open General
open Support.Common
module U = Support.Utils
module Qdom = Support.Qdom
module FeedAttr = Constants.FeedAttr
module AttrMap = Qdom.AttrMap

(** We attach this data to each SAT variable. *)
module SolverData =
  struct
    type t =
      | ImplElem of Feed.generic_implementation
      | CommandElem of Feed.command
      | MachineGroup of string
      | Interface of iface_uri      (* True if this interface is selected *)
    let to_string = function
      | ImplElem impl -> (Versions.format_version impl.Feed.parsed_version) ^ " - " ^ Qdom.show_with_loc impl.Feed.qdom
      | CommandElem command -> Qdom.show_with_loc command.Feed.command_qdom
      | MachineGroup name -> name
      | Interface iface -> iface
  end

module S = Support.Sat.MakeSAT(SolverData)

type decision_state =
  | Undecided of S.lit                  (* The next candidate to try *)
  | Selected of Feed.dependency list    (* The dependencies to check next *)
  | Unselected

type ('a, 'b) partition_result =
  | Left of 'a
  | Right of 'b

let partition fn lst =
  let pass = ref [] in
  let fail = ref [] in
  ListLabels.iter lst ~f:(fun item ->
    match fn item with
    | Left x -> pass := x :: !pass
    | Right x -> fail := x :: !fail
  );
  (List.rev !pass, List.rev !fail)

class type candidates =
  object
    method get_clause : S.at_most_one_clause option
    method get_vars : S.lit list
    method get_state : decision_state
  end

(* A dummy implementation, used to get diagnostic information if the solve fails. It satisfies all requirements,
   even conflicting ones. *)
let dummy_impl =
  let open Feed in {
    qdom = ZI.make "dummy";
    os = None;
    machine = None;
    stability = Testing;
    props = {
      attrs = AttrMap.empty;
      requires = [];
      commands = StringMap.empty;   (* (not used; we can provide any command) *)
      bindings = [];
    };
    parsed_version = Versions.dummy;
    impl_type = `local_impl "/dummy";
  }

(** A fake <command> used to generate diagnostics if the solve fails. *)
let dummy_command = {
  Feed.command_qdom = ZI.make "dummy-command";
  Feed.command_requires = [];
  Feed.command_bindings = [];
}

class impl_candidates (clause : S.at_most_one_clause option) (vars : (S.lit * Feed.generic_implementation) list) =
  object (_ : #candidates)
    method get_clause = clause

    (** Get just those implementations that have a command with this name. *)
    method get_commands name =
      let match_command (impl_var, impl) =
        match StringMap.find name impl.Feed.props.Feed.commands with
        | Some command -> Some (impl_var, command)
        | None when impl.Feed.parsed_version == Versions.dummy -> Some (impl_var, dummy_command)
        | None -> None in
      vars |> Support.Utils.filter_map match_command

    (** Get all variables, except dummy_impl (if present) *)
    method get_real_vars =
      vars |> Support.Utils.filter_map (fun (var, impl) ->
        if impl == dummy_impl then None
        else Some var
      )

    method get_vars =
      List.map (fun (var, _impl) -> var) vars

    method get_selected =
      match clause with
      | None -> None      (* There were never any candidates *)
      | Some clause ->
          match S.get_selected clause with
          | None -> None
          | Some lit ->
              match S.get_user_data_for_lit lit with
                | SolverData.ImplElem impl -> Some (lit, impl)
                | _ -> assert false

    method get_state =
      match clause with
      | None -> Unselected      (* There were never any candidates *)
      | Some clause ->
          match S.get_selected clause with
          | Some lit ->
              (* We've already chosen which <implementation> to use. Follow dependencies. *)
              let impl = match S.get_user_data_for_lit lit with
                | SolverData.ImplElem impl -> impl
                | _ -> assert false in
              Selected impl.Feed.props.Feed.requires
          | None ->
              match S.get_best_undecided clause with
              | Some lit -> Undecided lit
              | None -> Unselected        (* No remaining candidates, and none was chosen. *)

      (** Apply [test impl] to each implementation, partitioning the vars into two lists.
          Only defined for [impl_candidates]. *)
      method partition test = partition (fun (var, impl) -> if test impl then Left var else Right var) vars
  end

(** Holds all the commands with a given name within an interface. *)
class command_candidates (clause : S.at_most_one_clause option) (vars : (S.lit * Feed.command) list) =
  object (_ : #candidates)
    method get_clause = clause

    method get_vars =
      List.map (fun (var, _command) -> var) vars

    method get_state =
      match clause with
      | None -> Unselected      (* There were never any candidates *)
      | Some clause ->
          match S.get_selected clause with
          | Some lit ->
              (* We've already chosen which <command> to use. Follow dependencies. *)
              let command = match S.get_user_data_for_lit lit with
                | SolverData.CommandElem command -> command
                | _ -> assert false in
              Selected command.Feed.command_requires
          | None ->
              match S.get_best_undecided clause with
              | Some lit -> Undecided lit
              | None -> Unselected        (* No remaining candidates, and none was chosen. *)
  end

module type CACHE_ENTRY =
  sig
    type t
    type value
    val compare : t -> t -> int
  end

module CommandIfaceEntry =
  struct
    type t = (string * iface_uri * bool)
    type value = command_candidates
    let compare = compare
  end

module IfaceEntry =
  struct
    type t = (iface_uri * bool)
    type value = impl_candidates

    (* Sort the interfaces by URI so we have a stable output. *)
    let compare (ib, sb) (ia, sa) =
      match compare ia ib with
      | 0 -> compare sa sb
      | x -> x
  end

module Cache(CacheEntry : CACHE_ENTRY) :
  sig
    (** The cache is used in [build_problem], while the clauses are still being added. *)
    type t

    (** Once the problem is built, an immutable snapshot is taken. *)
    type snapshot

    val create : unit -> t

    (** [lookup cache make key] will look up [key] in [cache].
     * If not found, create it with [value, process = make key], add [value] to the cache,
     * and then call [process ()] on it.
     * [make] must not be recursive (since the key hasn't been added yet),
     * but [process] can be. In other words, [make] does whatever setup *must*
     * be done before anyone can use this cache entry, while [process] does
     * setup that can be done afterwards. *)
    val lookup : t -> (CacheEntry.t -> (CacheEntry.value * (unit -> unit))) -> CacheEntry.t -> CacheEntry.value

    val snapshot : t -> snapshot
    val get : CacheEntry.t -> snapshot -> CacheEntry.value option
    val get_exn : CacheEntry.t -> snapshot -> CacheEntry.value

    (** The sorted bindings *)
    val bindings : snapshot -> (CacheEntry.t * CacheEntry.value) list
  end = struct
    module M = Map.Make(CacheEntry)

    type snapshot = CacheEntry.value M.t
    type t = snapshot ref

    let create () = ref M.empty

    let lookup table make key =
      try M.find key !table
      with Not_found ->
        let value, process = make key in
        table := M.add key value !table;
        process ();
        value

    let snapshot table = !table

    let get key map =
      try Some (M.find key map)
      with Not_found -> None

    let get_exn = M.find
    let bindings = M.bindings
  end

module ImplCache = Cache(IfaceEntry)
module CommandCache = Cache(CommandIfaceEntry)

type requirements =
  | ReqCommand of CommandIfaceEntry.t
  | ReqIface of IfaceEntry.t

class type result =
  object
    method get_selections : Selections.t
    method get_selected : source:bool -> General.iface_uri -> Feed.generic_implementation option
    method impl_provider : Impl_provider.impl_provider
    method impl_provider : Impl_provider.impl_provider
    method implementations : ((General.iface_uri * bool) * (S.lit * Feed.generic_implementation) option) list
    method requirements : requirements
  end

type diagnostics = S.lit
let explain = S.explain_reason

(** Create a <selections> document from the result of a solve.
 * The use of Maps ensures that the inputs will be sorted, so we will have a stable output.
 *)
let get_selections dep_in_use root_req impls commands =
  (* For each implementation, remember which commands we need. *)
  let commands_needed = Hashtbl.create 10 in
  let check_command ((command_name, iface, _source), _) =
    Hashtbl.add commands_needed iface command_name in
  List.iter check_command commands;

  let selections = impls |> U.filter_map (fun ((iface, _source), impls) ->
    match impls#get_selected with
    | None -> None      (* This interface wasn't used *)
    | Some (_lit, impl) ->
        let attrs = Feed.(impl.props.attrs)
          |> AttrMap.remove ("", FeedAttr.stability)

          (* Replaced by <command> *)
          |> AttrMap.remove ("", FeedAttr.main)
          |> AttrMap.remove ("", FeedAttr.self_test)

          |> AttrMap.add_no_ns "interface" iface in

        let attrs =
          if Some iface = AttrMap.get_no_ns FeedAttr.from_feed attrs then (
            (* Don't bother writing from-feed attr if it's the same as the interface *)
            AttrMap.remove ("", FeedAttr.from_feed) attrs
          ) else attrs in

        let child_nodes = ref [] in
        if impl != dummy_impl then (
          let commands = Hashtbl.find_all commands_needed iface in
          let commands = List.sort compare commands in

          let copy_elem elem =
            (* Copy elem into parent (and strip out <version> elements). *)
            let open Qdom in
            let imported = {elem with
              child_nodes = List.filter (fun c -> ZI.tag c <> Some "version") elem.child_nodes;
            } in
            child_nodes := imported :: !child_nodes in

          let add_command name =
            let command = Feed.get_command_ex name impl in
            let command_elem = command.Feed.command_qdom in
            let want_command_child elem =
              (* We'll add in just the dependencies we need later *)
              match ZI.tag elem with
              | Some "requires" | Some "restricts" | Some "runner" -> false
              | _ -> true
            in
            let child_nodes = List.filter want_command_child command_elem.Qdom.child_nodes in
            let add_command_dep child_nodes dep =
              if dep.Feed.dep_importance <> Feed.Dep_restricts && dep_in_use dep then
                dep.Feed.dep_qdom :: child_nodes
              else
                child_nodes in
            let child_nodes = List.fold_left add_command_dep child_nodes command.Feed.command_requires in
            let command_elem = {command_elem with Qdom.child_nodes = child_nodes} in
            copy_elem command_elem in
          List.iter add_command commands;

          List.iter copy_elem impl.Feed.props.Feed.bindings;
          ListLabels.iter impl.Feed.props.Feed.requires ~f:(fun dep ->
            if dep_in_use dep && dep.Feed.dep_importance <> Feed.Dep_restricts then
              copy_elem (dep.Feed.dep_qdom)
          );

          impl.Feed.qdom |> ZI.iter ~name:"manifest-digest" copy_elem;
        );
        let sel = ZI.make
          ~attrs
          ~child_nodes:(List.rev !child_nodes)
          ~source_hint:impl.Feed.qdom "selection" in
        Some sel
  ) in

  let root_attrs =
    match root_req with
    | ReqCommand (command, iface, _source) ->
        AttrMap.singleton "interface" iface
        |> AttrMap.add_no_ns "command" command
    | ReqIface (iface, _source) ->
        AttrMap.singleton "interface" iface in
  ZI.make ~attrs:root_attrs ~child_nodes:(List.rev selections) "selections"

(* Make each interface conflict with its replacement (if any).
 * We do this at the end because if we didn't use the replacement feed, there's no need to conflict
 * (avoids getting it added to feeds_used). *)
let add_replaced_by_conflicts sat impl_clauses =
  List.iter (fun (source, clause, replacement) ->
    ImplCache.get (replacement, source) impl_clauses
    |> if_some (fun replacement_candidates ->
      (* Our replacement was also added to [sat], so conflict with it. *)
      let our_vars = clause#get_real_vars in
      let replacements = replacement_candidates#get_real_vars in
      if (our_vars <> [] && replacements <> []) then (
        (* Must select one implementation out of all candidates from both interfaces.
           Dummy implementations don't conflict, though. *)
        S.at_most_one sat (our_vars @ replacements) |> ignore
      )
    )
  )

(** On multi-arch systems, we can select 32-bit or 64-bit implementations, but not both in the same
 * set of selections. Returns a function that should be called for each implementation to add this
 * restriction. *)
let require_machine_groups sat =
  (* m64 is set if we select any 64-bit binary. mDef will be set if we select any binary that
     needs any other CPU architecture. Don't allow both to be set together. *)
  let machine_group_default = S.add_variable sat @@ SolverData.MachineGroup "mDef" in
  let machine_group_64 = S.add_variable sat @@ SolverData.MachineGroup "m64" in
  (* If we get to the end of the solve without deciding then nothing we selected cares about the
     type of CPU. The solver will set them both to false at the end. *)
  S.at_most_one sat [machine_group_default; machine_group_64] |> ignore;

  (* If [impl] requires a particular machine group, add a constraint to the problem. *)
  fun impl_var impl ->
    impl.Feed.machine |> if_some (function
      | "src" -> ()
      | machine ->
          let group_var =
            let open Arch in
            match get_machine_group machine with
            | Machine_group_default -> machine_group_default
            | Machine_group_64 -> machine_group_64 in
          S.implies sat ~reason:"machine group" impl_var [group_var];
    )

(** If this binding depends on a command (<executable-in-*>), add that to the problem.
 * @param user_var indicates when this binding is used
 * @param dep_iface the required interface this binding targets *)
let process_self_binding sat lookup_command user_var dep_iface binding =
  Binding.parse_binding binding
  |> pipe_some Binding.get_command
  |> if_some (fun name ->
    (* Note: we only call this for self-bindings, so we could be efficient by selecting the exact command here... *)
    let candidates = lookup_command (name, dep_iface, false) in
    S.implies sat ~reason:"binding on command" user_var candidates#get_vars
  )

(* Process a dependency of [user_var]:
   - find the candidate implementations/commands to satisfy it
   - take just those that satisfy any restrictions in the dependency
   - ensure that we don't pick an incompatbile version if we select [user_var]
   - ensure that we do pick a compatible version if we select [user_var] (for "essential" dependencies only) *)
let process_dep sat lookup_impl lookup_command user_var dep =
  (* Restrictions on the candidates *)
  let meets_restriction impl r = impl.Feed.parsed_version = Versions.dummy || r#meets_restriction impl in
  let meets_restrictions impl = List.for_all (meets_restriction impl) dep.Feed.dep_restrictions in
  let candidates = lookup_impl (dep.Feed.dep_iface, false) in
  let pass, fail = candidates#partition meets_restrictions in

  (* Dependencies on commands *)
  dep.Feed.dep_required_commands |> List.iter (fun name ->
    let candidates = lookup_command (name, dep.Feed.dep_iface, false) in

    if dep.Feed.dep_importance = Feed.Dep_essential then (
      S.implies sat ~reason:"dep on command" user_var candidates#get_vars
    ) else (
      (* An optional dependency is selected when any implementation of the target interface
       * is selected. Force [dep_iface_selected] to be true in that case. We only need to test
       * [pass] here, because we always avoid [fail] anyway. *)
      let dep_iface_selected = S.add_variable sat (SolverData.Interface dep.Feed.dep_iface) in
      S.at_most_one sat (S.neg dep_iface_selected :: pass) |> ignore;

      (* If user_var is selected, then either we don't select this interface, or we select
       * a suitable command. *)
      S.implies sat ~reason:"opt dep on command" user_var (S.neg dep_iface_selected :: candidates#get_vars)
    );
  );

  if dep.Feed.dep_importance = Feed.Dep_essential then (
    S.implies sat ~reason:"essential dep" user_var pass     (* Must choose a suitable candidate *)
  ) else (
    (* If [user_var] is selected, don't select an incompatible version of the optional dependency.
       We don't need to do this explicitly in the [essential] case, because we must select a good
       version and we can't select two. *)
    S.at_most_one sat (user_var :: fail) |> ignore;
  )

(* Add the implementations of an interface to the ImplCache (called the first time we visit it). *)
let make_impl_clause sat ~closest_match replacements impl_provider iface_uri ~source =
  let {Impl_provider.replacement; impls; rejects = _} = impl_provider#get_implementations iface_uri ~source in

  (* Insert dummy_impl (last) if we're trying to diagnose a problem. *)
  let impls =
    if closest_match then impls @ [dummy_impl]
    else impls in

  let impls = impls
    |> List.map (fun impl ->
        let var = S.add_variable sat (SolverData.ImplElem impl) in
        (var, impl)
    ) in
  let impl_clause = if impls <> [] then Some (S.at_most_one sat (List.map fst impls)) else None in
  let clause = new impl_candidates impl_clause impls in

  (* If we have a <replaced-by>, remember to add a conflict with our replacement *)
  replacement |> if_some (fun replacement ->
    if replacement = iface_uri then log_warning "Interface %s replaced-by itself!" iface_uri
    else replacements := (source, clause, replacement) :: !replacements;
  );

  clause, impls

(* Create a new CommandCache entry (called the first time we request this key). *)
let make_commands_clause sat lookup_impl process_self_bindings process_deps key =
  let (command, iface, source) = key in
  let impls = lookup_impl (iface, source) in
  let commands = impls#get_commands command in
  let make_provides_command (_impl, elem) =
    (** [var] will be true iff this <command> is selected. *)
    let var = S.add_variable sat (SolverData.CommandElem elem) in
    (var, elem) in
  let vars = List.map make_provides_command commands in
  let command_clause = if vars <> [] then Some (S.at_most_one sat @@ List.map fst vars) else None in
  let data = new command_candidates command_clause vars in

  (data, fun () ->
    let depend_on_impl (command_var, command) (impl_var, _command) =
      (* For each command, require that we select the corresponding implementation. *)
      S.implies sat ~reason:"impl for command" command_var [impl_var];
      (* Commands can depend on other commands in the same implementation *)
      process_self_bindings command_var iface command.Feed.command_bindings;
      (* Process command-specific dependencies *)
      process_deps command_var command.Feed.command_requires;
    in
    List.iter2 depend_on_impl vars commands
  )

(** Starting from [root_req], explore all the feeds, commands and implementations we might need, adding
 * all of them to [sat_problem]. *)
let build_problem impl_provider root_req sat ~closest_match =
  (* For each (iface, command, source) we have a list of implementations (or commands). *)
  let impl_cache = ImplCache.create () in
  let command_cache = CommandCache.create () in

  let require_machine_group = require_machine_groups sat in

  (* Handle <replaced-by> conflicts after building the problem. *)
  let replacements = ref [] in

  let rec add_impls_to_cache (iface_uri, source) =
    let clause, impls = make_impl_clause sat ~closest_match replacements impl_provider iface_uri ~source in
    (clause, fun () ->
      impls |> List.iter (fun (impl_var, impl) ->
        require_machine_group impl_var impl;
        process_self_bindings impl_var iface_uri Feed.(impl.props.bindings);
        process_deps impl_var Feed.(impl.props.requires);
      )
    )
  and add_commands_to_cache key = make_commands_clause sat lookup_impl process_self_bindings process_deps key
  and lookup_impl key = ImplCache.lookup impl_cache add_impls_to_cache key
  and lookup_command key = CommandCache.lookup command_cache add_commands_to_cache key
  and process_self_bindings user_var dep_iface = List.iter (process_self_binding sat lookup_command user_var dep_iface)
  and process_deps user_var = List.iter (fun dep ->
    if impl_provider#is_dep_needed dep then process_dep sat lookup_impl lookup_command user_var dep
  ) in

  (* This recursively builds the whole problem up. *)
  begin match root_req with
    | ReqIface r -> (lookup_impl r)#get_vars
    | ReqCommand r -> (lookup_command r)#get_vars end
  |> S.at_least_one sat ~reason:"need root";          (* Must get what we came for! *)

  (* All impl_candidates and command_candidates have now been added, so snapshot the cache. *)
  let impl_clauses, command_clauses = ImplCache.snapshot impl_cache, CommandCache.snapshot command_cache in
  add_replaced_by_conflicts sat impl_clauses !replacements;
  impl_clauses, command_clauses

let do_solve (impl_provider:Impl_provider.impl_provider) root_req ~closest_match =
  (* The basic plan is this:
     1. Scan the root interface and all dependencies recursively, building up a SAT problem.
     2. Solve the SAT problem. Whenever there are multiple options, try the most preferred one first.
     3. Create the selections XML from the results.

     All three involve recursively walking the tree in a similar way:
     1) we follow every dependency of every implementation (order not important)
     2) we follow every dependency of every selected implementation (better versions first)
     3) we follow every dependency of every selected implementation

     In all cases, a dependency may be on an <implementation> or on a specific <command>.
   *)

  let sat = S.create () in

  let impl_clauses, command_clauses = build_problem impl_provider root_req sat ~closest_match in

  let lookup = function
    | ReqIface r -> (ImplCache.get_exn r impl_clauses :> candidates)
    | ReqCommand r -> (CommandCache.get_exn r command_clauses) in

  let dep_in_use dep = impl_provider#is_dep_needed dep in

  (* Run the solve *)

  let decider () =
    (* Walk the current solution, depth-first, looking for the first undecided interface.
       Then try the most preferred implementation of it that hasn't been ruled out. *)
    let seen = Hashtbl.create 100 in
    let rec find_undecided req =
      if Hashtbl.mem seen req then None    (* Break cycles *)
      else (
        Hashtbl.add seen req true;
        let candidates = lookup req in
        match candidates#get_state with
        | Unselected -> None
        | Undecided lit -> Some lit
        | Selected deps ->
            (* We've already selected a candidate for this component. Now check its dependencies. *)

            let check_dep dep =
              if dep.Feed.dep_importance = Feed.Dep_restricts || not (dep_in_use dep) then (
                (* Restrictions don't express that we do or don't want the
                   dependency, so skip them here. If someone else needs this,
                   we'll handle it when we get to them.
                   If noone wants it, it will be set to unselected at the end. *)
                None
              ) else (
                let dep_iface = dep.Feed.dep_iface in
                match find_undecided @@ ReqIface (dep_iface, false) with
                | Some lit -> Some lit
                | None ->
                    (* Command dependencies next *)
                    let check_command_dep name = find_undecided @@ ReqCommand (name, dep_iface, false) in
                    Support.Utils.first_match check_command_dep dep.Feed.dep_required_commands
              )
              in
            match Support.Utils.first_match check_dep deps with
            | Some lit -> Some lit
            | None ->   (* All dependencies checked; now to the impl (if we're a <command>) *)
                match req with
                | ReqCommand (_command, iface, source) -> find_undecided @@ ReqIface (iface, source)
                | ReqIface _ -> None     (* We're not a <command> *)
      ) in
    find_undecided root_req in

  match S.run_solver sat decider with
  | None -> None
  | Some _solution ->
      (* Build the results object *)
      Some (
      object (_ : result)
        method get_selections =
          let was_selected (_, candidates) =
            match candidates#get_clause with
            | None -> false
            | Some clause -> S.get_selected clause <> None in

          let commands = command_clauses |> CommandCache.bindings |> List.filter was_selected in
          let impls = impl_clauses |> ImplCache.bindings |> List.filter was_selected in
          get_selections dep_in_use root_req impls commands |> Selections.create

        method get_selected ~source iface =
          ImplCache.get (iface, source) impl_clauses
          |> pipe_some (fun candidates ->
              match candidates#get_selected with
              | Some (_lit, impl) when impl != dummy_impl -> Some impl
              | _ -> None
          )

        method impl_provider = impl_provider

        method implementations =
          impl_clauses |> ImplCache.bindings |> List.map (fun (key, impl_candidates) -> (key, impl_candidates#get_selected))

        method requirements = root_req
      end
  )

let get_root_requirements config requirements =
  let { Requirements.command; interface_uri; source; extra_restrictions; os; cpu; message = _ } = requirements in

  (* This is for old feeds that have use='testing' instead of the newer
    'test' command for giving test-only dependencies. *)
  let use = if command = Some "test" then StringSet.singleton "testing" else StringSet.empty in

  let platform = config.system#platform in
  let os = default platform.Platform.os os in
  let machine = default platform.Platform.machine cpu in

  (* Disable multi-arch on Linux if the 32-bit linker is missing. *)
  let multiarch = os <> "Linux" || config.system#file_exists "/lib/ld-linux.so.2" in

  let scope_filter = Impl_provider.({
    extra_restrictions = StringMap.map Feed.make_version_restriction extra_restrictions;
    os_ranks = Arch.get_os_ranks os;
    machine_ranks = Arch.get_machine_ranks ~multiarch machine;
    languages = config.langs;
    allowed_uses = use;
  }) in

  let root_req = match command with
  | Some command -> ReqCommand (command, interface_uri, source)
  | None -> ReqIface (interface_uri, source) in

  (scope_filter, root_req)

let solve_for config feed_provider requirements =
  try
    let scope_filter, root_req = get_root_requirements config requirements in

    let impl_provider = (new Impl_provider.default_impl_provider config feed_provider scope_filter :> Impl_provider.impl_provider) in
    match do_solve impl_provider root_req ~closest_match:false with
    | Some result -> (true, result)
    | None ->
        match do_solve impl_provider root_req ~closest_match:true with
        | Some result -> (false, result)
        | None -> failwith "No solution, even with closest_match!"
  with Safe_exception _ as ex -> reraise_with_context ex "... solving for interface %s" requirements.Requirements.interface_uri
