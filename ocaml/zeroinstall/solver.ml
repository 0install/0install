(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Select a compatible set of components to run a program. *)

open General
open Support.Common
module Qdom = Support.Qdom

(** We attach this data to each SAT variable. *)
module SolverData =
  struct
    type t =
      | Unused        (* This is just here to make the compiler happy. *)
      | ImplElem of Feed.implementation
      | CommandElem of Feed.command
      | MachineGroup of string
    let to_string = function
      | ImplElem impl -> (Versions.format_version impl.Feed.parsed_version) ^ " - " ^ Qdom.show_with_loc impl.Feed.qdom
      | CommandElem command -> Qdom.show_with_loc command.Feed.command_qdom
      | MachineGroup name -> name
      | Unused -> assert false
    let unused = Unused
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
    method get_vars : S.var list
    method get_state : decision_state
  end

(* A dummy implementation, used to get diagnostic information if the solve fails. It satisfies all requirements,
   even conflicting ones. *)
let dummy_impl =
  let open Feed in {
    qdom = ZI.make_root "dummy";
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
    impl_type = PackageImpl { package_installed = true; package_distro = "dummy" };
  }

(** A fake <command> used to generate diagnostics if the solve fails. *)
let dummy_command = {
  Feed.command_qdom = ZI.make_root "dummy-command";
  Feed.command_requires = [];
}

class impl_candidates sat (clause : S.at_most_one_clause option) (vars : (S.var * Feed.implementation) list) =
  object (_ : #candidates)
    method get_clause = clause

    (** Get just those implementations that have a command with this name. *)
    method get_commands name =
      let match_command (impl_var, impl) =
        try Some (impl_var, StringMap.find name impl.Feed.props.Feed.commands)
        with Not_found ->
          if impl.Feed.parsed_version == Versions.dummy then
            Some (impl_var, dummy_command)
          else
            None
      in
      Support.Utils.filter_map vars ~f:match_command

    (** Get all variables, except dummy_impl (if present) *)
    method get_real_vars =
      Support.Utils.filter_map vars ~f:(fun (var, impl) ->
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
              match (S.get_varinfo_for_lit sat lit).S.obj with
                | SolverData.ImplElem impl -> Some (lit, impl)
                | _ -> assert false

    method get_state =
      match clause with
      | None -> Unselected      (* There were never any candidates *)
      | Some clause ->
          match S.get_selected clause with
          | Some lit ->
              (* We've already chosen which <implementation> to use. Follow dependencies. *)
              let impl = match (S.get_varinfo_for_lit sat lit).S.obj with
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
class command_candidates sat (clause : S.at_most_one_clause option) (vars : (S.var * Feed.command) list) =
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
              let command = match (S.get_varinfo_for_lit sat lit).S.obj with
                | SolverData.CommandElem command -> command
                | _ -> assert false in
              Selected command.Feed.command_requires
          | None ->
              match S.get_best_undecided clause with
              | Some lit -> Undecided lit
              | None -> Unselected        (* No remaining candidates, and none was chosen. *)
  end

(** To avoid adding the same implementations and commands more than once, we
    cache them. *)
type search_key =
  | ReqCommand of (string * iface_uri * bool)
  | ReqIface of (iface_uri * bool)

class ['a, 'b] cache =
  object
    val table : ('a, 'b) Hashtbl.t = Hashtbl.create 100
    val mutable make : 'a -> ('b * (unit -> unit)) = fun _ -> failwith "set_maker not called!"

    method set_maker maker =
      make <- maker

    (** Look up [key] in [cache]. If not found, create it with [make key],
        add it to the cache, and then call [process key value] on it.
        [make] must not be recursive (since the key hasn't been added yet),
        but [process] can be. In other words, [make] does whatever setup *must*
        be done before anyone can use this cache entry, which [process] does
        setup that can be done afterwards. *)
    method lookup (key:'a) : 'b =
      try Hashtbl.find table key
      with Not_found ->
        let (value, process) = make key in
        Hashtbl.add table key value;
        process ();
        value

    method peek (key:'a) : 'b option =
      try Some (Hashtbl.find table key)
      with Not_found -> None

    method get_items =
      let r = ref [] in
      Hashtbl.iter (fun k v ->
        r := (k, v) :: !r;
      ) table;
      !r
  end

type scope = {
  scope_filter : Impl_provider.scope_filter;
  use : StringSet.t;        (* For the old <requires use='...'/> *)
}

class type result =
  object
    method get_selections : Qdom.element
    method get_details : (scope * S.sat_problem * Impl_provider.impl_provider *
                          (General.iface_uri * bool, impl_candidates) cache * search_key)
  end

(** Create a <selections> document from the result of a solve. *)
let get_selections dep_in_use root_req impl_cache command_cache =
  let root = ZI.make_root "selections" in
  let root_iface =
    match root_req with
    | ReqCommand (command, iface, _source) ->
        root.Qdom.attrs <- (("", "command"), command) :: root.Qdom.attrs;
        iface
    | ReqIface (iface, _source) -> iface in
  root.Qdom.attrs <- (("", "interface"), root_iface) :: root.Qdom.attrs;

  let was_selected (_, candidates) =
    match candidates#get_clause with
    | None -> false
    | Some clause -> S.get_selected clause <> None in

  let commands = List.filter was_selected @@ command_cache#get_items in
  let impls = List.filter was_selected @@ impl_cache#get_items in

  (* For each implementation, remember which commands we need. *)
  let commands_needed = Hashtbl.create 10 in
  let check_command ((command_name, iface, _source), _) =
    Hashtbl.add commands_needed iface command_name in
  List.iter check_command commands;

  (* Sort the interfaces by URI so we have a stable output. *)
  let cmp ((ib, sb), _cands) ((ia, sa), _cands) =
    match compare ia ib with
    | 0 -> compare sa sb
    | x -> x in
  let impls = List.sort cmp impls in

  let add_impl ((iface, _source), impls) : unit =
    match impls#get_selected with
    | None -> ()      (* This interface wasn't used *)
    | Some (_lit, impl) ->
        let attrs = ref impl.Feed.props.Feed.attrs in
        let set_attr name value =
          attrs := Feed.AttrMap.add ("", name) value !attrs in

        attrs := Feed.AttrMap.remove ("", Feed.attr_stability) !attrs;

        (* Replaced by <command> *)
        attrs := Feed.AttrMap.remove ("", Feed.attr_main) !attrs;
        attrs := Feed.AttrMap.remove ("", Feed.attr_self_test) !attrs;

        if Some iface = Feed.get_attr_opt Feed.attr_from_feed !attrs then (
          (* Don't bother writing from-feed attr if it's the same as the interface *)
          attrs := Feed.AttrMap.remove ("", Feed.attr_from_feed) !attrs
        );

        set_attr "interface" iface;

        let sel = ZI.insert_first "selection" root in
        if impl != dummy_impl then (
          let commands = Hashtbl.find_all commands_needed iface in
          let commands = List.sort compare commands in

          let copy_elem parent elem =
            (* Copy elem into parent (and strip out <version> elements). *)
            let open Qdom in
            let imported = import_node elem parent.doc in
            imported.child_nodes <- List.filter (fun c -> ZI.tag c <> Some "version") imported.child_nodes;
            prepend_child imported parent in

          let add_command name =
            let command = Feed.get_command impl name in
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
            copy_elem sel command_elem in
          List.iter add_command commands;

          List.iter (copy_elem sel) impl.Feed.props.Feed.bindings;
          ListLabels.iter impl.Feed.props.Feed.requires ~f:(fun dep ->
            if dep_in_use dep && dep.Feed.dep_importance <> Feed.Dep_restricts then
              copy_elem sel (dep.Feed.dep_qdom)
          );

          ZI.iter_with_name impl.Feed.qdom "manifest-digest" ~f:(copy_elem sel);

          sel.Qdom.child_nodes <- List.rev sel.Qdom.child_nodes
        );
        assert (sel.Qdom.attrs = []);
        sel.Qdom.attrs <- Feed.AttrMap.bindings !attrs
    in
  List.iter add_impl impls;
  root

(* [closest_match] is used internally. It adds a lowest-ranked
   (but valid) implementation to every interface, so we can always
   select something. Useful for diagnostics. *)
let do_solve (impl_provider:Impl_provider.impl_provider) root_scope root_req ~closest_match =
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

  (* For each (iface, command, source) we have a list of implementations (or commands). *)
  let impl_cache = new cache in
  let command_cache = new cache in

  (* m64 is set if we select any 64-bit binary. mDef will be set if we select any binary that
     needs any other CPU architecture. Don't allow both to be set together. *)
  let machine_group_default = S.add_variable sat @@ SolverData.MachineGroup "mDef" in
  let machine_group_64 = S.add_variable sat @@ SolverData.MachineGroup "m64" in
  (* If we get to the end of the solve without deciding then nothing we selected cares about the
     type of CPU. The solver will set them both to false at the end. *)
  ignore @@ S.at_most_one sat [machine_group_default; machine_group_64];

  (* Insert dummy_impl if we're trying to diagnose a problem. *)
  let maybe_add_dummy impls =
    if closest_match then (
      impls @ [dummy_impl]
    ) else (
      impls
    ) in

  let dep_in_use dep =
    match dep.Feed.dep_use with
    | Some use when not (StringSet.mem use root_scope.use) -> false
    | None | Some _ ->
        (* Ignore dependency if 'os' attribute is present and doesn't match *)
        match dep.Feed.dep_if_os with
        | Some required_os -> StringMap.mem required_os root_scope.scope_filter.Impl_provider.os_ranks
        | None -> true
  in

  (* Callbacks to run after building the problem. *)
  let delayed = ref [] in

  (* For each dependency of [user_var]:
     - find the candidate implementations to satisfy it
     - take just those that satisfy any restrictions in the dependency
     - ensure that we don't pick an incompatbile version if we select [user_var]
     - ensure that we do pick a compatible version if we select [user_var] (for "essential" dependencies only)
     - if we require any commands, ensure we select them too
  *)
  let rec process_deps user_var deps =
    ListLabels.iter deps ~f:(fun dep ->
      if dep_in_use dep then (
        let essential = (dep.Feed.dep_importance = Feed.Dep_essential) in

        (* Dependencies on commands *)
        let require_command name =
          (* What about optional command dependencies? Looks like the Python doesn't handle that either... *)
          let candidates = command_cache#lookup @@ (name, dep.Feed.dep_iface, false) in
          S.implies sat ~reason:"dep on command" user_var (candidates#get_vars) in
        List.iter require_command dep.Feed.dep_required_commands;

        (* Restrictions on the candidates *)
        let meets_restriction impl r :bool = impl.Feed.parsed_version = Versions.dummy || r#meets_restriction impl in
        let meets_restrictions impl = List.for_all (meets_restriction impl) dep.Feed.dep_restrictions in
        let candidates = impl_cache#lookup @@ (dep.Feed.dep_iface, false) in
        let (pass, fail) = candidates#partition meets_restrictions in

        if essential then (
          (*
          if pass = [] then (
            let impl_str = SolverData.to_string (S.get_varinfo_for_lit sat user_var).S.obj in
            log_warning "Discarding candidate '%s' because dep %s cannot be satisfied. %d/%d candidates pass the restrictions."
              impl_str (Qdom.show_with_loc dep.Feed.dep_qdom) (List.length pass) (List.length fail)
          );
          *)

          S.implies sat ~reason:"essential dep" user_var pass     (* Must choose a suitable candidate *)
        ) else (
          ListLabels.iter fail ~f:(fun bad_impl ->
            (* If [user_var] is selected, don't select an incompatible version of the optional dependency.
               We don't need to do this explicitly in the [essential] case, because we must select a good
               version and we can't select two. *)
            S.implies sat ~reason:"conflicting dep" user_var [S.neg bad_impl]
          )
        )
      )
    )

  (* Add the implementations of an interface to the cache (called the first time we visit it). *)
  and add_impls_to_cache (iface_uri, source) =
    let {Impl_provider.replacement; Impl_provider.impls; Impl_provider.rejects = _} =
      impl_provider#get_implementations root_scope.scope_filter iface_uri ~source in
    (* log_warning "Adding %d impls for %s" (List.length impls) iface_uri; *)
    let matching_impls = maybe_add_dummy @@ impls in
    let pairs = List.map (fun impl -> (S.add_variable sat (SolverData.ImplElem impl), impl)) matching_impls in
    let impl_clause = if List.length pairs > 0 then Some (S.at_most_one sat (List.map fst pairs)) else None in
    let data = new impl_candidates sat impl_clause pairs in
    (data, fun () ->
      (* Conflict with our replacements *)
      let () =
        match replacement with
        | None -> ()
        | Some replacement when replacement = iface_uri ->
            log_warning "Interface %s replaced-by itself!" iface_uri
        | Some replacement ->
            let handle_replacement () =
              let our_vars = data#get_real_vars in
              match impl_cache#peek (replacement, source) with
              | None -> ()  (* We didn't use it, so we can't conflict *)
              | Some replacement_candidates ->
                  let replacements = replacement_candidates#get_real_vars in
                  if (our_vars <> [] && replacements <> []) then (
                    (* Must select one implementation out of all candidates from both interfaces.
                       Dummy implementations don't conflict, though. *)
                    ignore @@ S.at_most_one sat (our_vars @ replacements)
                  ) in
            (* Delay until the end. If we never use the replacement feed, no need to conflict
               (avoids getting it added to feeds_used). *)
            delayed := handle_replacement :: !delayed
      in

      ListLabels.iter pairs ~f:(fun (impl_var, impl) ->
        let () =
          let open Arch in
          match impl.Feed.machine with
          | Some machine when machine <> "src" -> (
              let group_var =
                match get_machine_group machine with
                | Machine_group_default -> machine_group_default
                | Machine_group_64 -> machine_group_64 in
              S.implies sat ~reason:"machine group" impl_var [group_var];
          )
          | _ -> () in

        (* Process dependencies *)
        process_deps impl_var impl.Feed.props.Feed.requires
      )
    )

  (* Initialise this cache entry (called the first time we request this key). *)
  and add_commands_to_cache (command, iface, source) =
    let impls = impl_cache#lookup @@ (iface, source) in
    let commands = impls#get_commands command in
    let make_provides_command (_impl, elem) =
      (** [var] will be true iff this <command> is selected. *)
      let var = S.add_variable sat (SolverData.CommandElem elem) in
      (var, elem) in
    let vars = List.map make_provides_command commands in
    let command_clause = if List.length vars > 0 then Some (S.at_most_one sat @@ List.map fst vars) else None in
    let data = new command_candidates sat command_clause vars in

    let process_commands () =
      let depend_on_impl (command_var, command) (impl_var, _command) =
        (* For each command, require that we select the corresponding implementation. *)
        S.implies sat ~reason:"impl for command" command_var [impl_var];
        (* Process command-specific dependencies *)
        process_deps command_var command.Feed.command_requires;
      in
      List.iter2 depend_on_impl vars commands in

    (data, process_commands) in

  (* Can't work out how to set these in the constructor call, so do it here instead. *)
  impl_cache#set_maker add_impls_to_cache;
  command_cache#set_maker add_commands_to_cache;

  let lookup = function
    | ReqIface r -> (impl_cache#lookup r :> candidates)
    | ReqCommand r -> command_cache#lookup r in

  (* This recursively builds the whole problem up. *)
  let candidates = lookup root_req in
  S.at_least_one sat ~reason:"need root" @@ candidates#get_vars;          (* Must get what we came for! *)

  (* Setup done; lock to prevent accidents *)
  let locked _ = failwith "building done" in
  impl_cache#set_maker locked;
  command_cache#set_maker locked;

  (* Run all the callbacks *)
  List.iter (fun fn -> fn ()) !delayed;

  (* Run the solve *)

  let decider () =
    (* Walk the current solution, depth-first, looking for the first undecided interface.
       Then try the most preferred implementation of it that hasn't been ruled out. *)
    let seen = Hashtbl.create 100 in
    let rec find_undecided req =
      if Hashtbl.mem seen req then (
        None    (* Break cycles *)
      ) else (
        Hashtbl.add seen req true;
(*
        let () = match req with
          | ReqCommand (command, iface, _source) -> log_warning "check %s %s" iface command
          | ReqIface (iface, _source) -> log_warning "check %s" iface in
*)
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
      )
      in
    find_undecided root_req in

  (* Build the results object *)

  match S.run_solver sat decider with
  | None -> None
  | Some _solution ->
      Some (
      object (_ : result)
        method get_selections = get_selections dep_in_use root_req impl_cache command_cache

        method get_details =
          if closest_match then
            (root_scope, sat, impl_provider, impl_cache, root_req)
          else
            failwith "Can't diagnostic details: solve didn't fail!"
      end
  )

let get_root_requirements config requirements =
  let open Requirements in
  let {
    command; interface_uri; source;
    extra_restrictions; os; cpu;
    message = _;
  } = requirements in

  (* This is for old feeds that have use='testing' instead of the newer
    'test' command for giving test-only dependencies. *)
  let use = if command = Some "test" then StringSet.singleton "testing" else StringSet.empty in

  let platform = config.system#platform () in
  let os = default platform.Platform.os os in
  let machine = default platform.Platform.machine cpu in

  (* Disable multi-arch on Linux if the 32-bit linker is missing. *)
  let multiarch = os <> "Linux" || config.system#file_exists "/lib/ld-linux.so.2" in

  let open Impl_provider in
  let scope_filter = {
    extra_restrictions = StringMap.map Feed.make_version_restriction extra_restrictions;
    os_ranks = Arch.get_os_ranks os;
    machine_ranks = Arch.get_machine_ranks ~multiarch machine;
    languages = Support.Locale.get_langs config.system;
  } in
  let scope = { scope_filter; use } in

  let root_req = match command with
  | Some command -> ReqCommand (command, interface_uri, source)
  | None -> ReqIface (interface_uri, source) in

  (scope, root_req)

let solve_for config feed_provider requirements =
  try
    let (scope, root_req) = get_root_requirements config requirements in

    let impl_provider = (new Impl_provider.default_impl_provider config feed_provider :> Impl_provider.impl_provider) in
    match do_solve impl_provider scope root_req ~closest_match:false with
    | Some result -> (true, result)
    | None ->
        match do_solve impl_provider scope root_req ~closest_match:true with
        | Some result -> (false, result)
        | None -> failwith "No solution, even with closest_match!"
  with Safe_exception _ as ex -> reraise_with_context ex "... solving for interface %s" requirements.Requirements.interface_uri
