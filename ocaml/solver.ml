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
    let to_string = function
      | ImplElem impl -> (Versions.format_version impl.Feed.parsed_version) ^ " - " ^ Qdom.show_with_loc impl.Feed.qdom
      | CommandElem command -> Qdom.show_with_loc command.Feed.command_qdom
      | Unused -> assert false
    let unused = Unused
  end

module S = Sat.MakeSAT(SolverData)

type decision_state =
  | Undecided of S.lit                  (* The next candidate to try *)
  | Selected of Feed.dependency list    (* The dependencies to check next *)
  | Unselected

let partition fn lst =
  let pass = ref [] in
  let fail = ref [] in
  ListLabels.iter lst ~f:(fun item ->
    match fn item with
    | (true, x) -> pass := x :: !pass
    | (false, x) -> fail := x :: !fail
  );
  (List.rev !pass, List.rev !fail)

class type candidates =
  object
    method get_clause : unit -> S.at_most_one_clause option
    method get_commands : string -> (S.var * Feed.command) list
    method get_vars : unit -> S.var list
    method get_state : S.sat_problem -> decision_state

    (** Apply [test impl] to each implementation, partitioning the vars into two lists.
        Only defined for [impl_candidates]. *)
    method partition : (Feed.implementation -> bool) -> (S.var list * S.var list)
  end

(** A fake <command> used to generate diagnostics if the solve fails. *)
let dummy_command = {
  Feed.command_qdom = ZI.make_root "dummy-command";
  Feed.command_requires = [];
}

class impl_candidates (clause : S.at_most_one_clause option) (vars : (S.var * Feed.implementation) list) =
  object (_ : #candidates)
    method get_clause () = clause

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

    method get_vars () =
      List.map (fun (var, _impl) -> var) vars

    method get_state sat =
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

      method partition test = partition (fun (var, impl) -> (test impl, var)) vars
  end

(** Holds all the commands with a given name within an interface. *)
class command_candidates (clause : S.at_most_one_clause option) (vars : (S.var * Feed.command) list) =
  object (_ : #candidates)
    method get_clause () = clause

    method get_commands _name = failwith "get_command on a <command>!"

    method get_vars () =
      List.map (fun (var, _command) -> var) vars

    method get_state sat =
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

    method partition _test = failwith "can't partition commands"
  end

(** To avoid adding the same implementations and commands more than once, we
    cache them. *)
type cache_key = (string option * iface_uri * bool)
class cache =
  object
    val table : (cache_key, candidates) Hashtbl.t = Hashtbl.create 100
    val mutable make : cache_key -> (candidates * (unit -> unit)) = fun _ -> failwith "set_maker not called!"

    method set_maker maker =
      make <- maker

    (** Look up [key] in [cache]. If not found, create it with [make key],
        add it to the cache, and then call [process key value] on it.
        [make] must not be recursive (since the key hasn't been added yet),
        but [process] can be. In other words, [make] does whatever setup *must*
        be done before anyone can use this cache entry, which [process] does
        setup that can be done afterwards. *)
    method lookup (key:cache_key) : candidates =
      try Hashtbl.find table key
      with Not_found ->
        let (value, process) = make key in
        Hashtbl.add table key value;
        process ();
        value

    method iter (fn:cache_key -> candidates -> unit) =
      Hashtbl.iter fn table
  end

(* TODO *)
type scope = {
  extra_restrictions : Versions.version_expr StringMap.t;   (* iface -> expr *)
  (*
  os : string;
  cpu : string;
  *)
  use : StringSet.t;        (* For the old <requires use='...'/> *)
}

class type result =
  object
    method get_selections : unit -> Qdom.element
  end

class type solver =
  object
    (** Returns whether or not a full solution was found and the solution.
        If a full solution is not found, [result] can still be used to provide
        diagnostic information. *)
    method solve : Requirements.requirements -> (bool * result)
  end

let get_root_req requirements =
  let {
    Requirements.interface_uri; Requirements.command; Requirements.source;
    Requirements.extra_restrictions;
    Requirements.os; Requirements.cpu;
    Requirements.message = _message;
  } = requirements in

  ignore (os, cpu);

  let root_req = (command, interface_uri, source) in

  (* This is for old feeds that have use='testing' instead of the newer
    'test' command for giving test-only dependencies. *)
  let use = if command = Some "test" then StringSet.singleton "testing" else StringSet.empty in

  let root_scope = {
    extra_restrictions = StringMap.map (fun v -> Versions.parse_expr v) extra_restrictions;
    (*
    os = default Arch.host_os os;
    cpu = default Arch.host_cpu cpu;
    *)
    use;
  }

  in (root_scope, root_req)

(* A dummy implementation, used to get diagnostic information if the solve fails. It satisfies all requirements,
   even conflicting ones. *)
let dummy_impl =
  let open Feed in {
    qdom = ZI.make_root "dummy";
    os = None;
    machine = None;
    props = {
      attrs = AttrMap.empty;
      requires = [];
      commands = StringMap.empty;   (* (not used; we can provide any command) *)
      bindings = [];
    };
    parsed_version = Versions.dummy;
  }

(* [closest_match] is used internally. It adds a lowest-ranked
   (but valid) implementation to every interface, so we can always
   select something. Useful for diagnostics. *)
let solve_for impl_provider requirements ~closest_match =
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
  let cache = new cache in

  (* TODO: extra_restrictions, etc *)
  let (_root_scope, root_req) = get_root_req requirements in

  (* Insert dummy_impl if we're trying to diagnose a problem. *)
  let maybe_add_dummy impls =
    if closest_match then (
      impls @ [dummy_impl]
    ) else (
      impls
    ) in

  (* For each dependency of [user_var]:
     - find the candidate implementations to satisfy it
     - take just those that satisfy any restrictions in the dependency
     - ensure that we don't pick an incompatbile version if we select [user_var]
     - ensure that we do pick a compatible version if we select [user_var] (for "essential" dependencies only)
     - if we require any commands, ensure we select them too
  *)
  let rec process_deps user_var deps =
    ListLabels.iter deps ~f:(fun dep ->
      let essential = (dep.Feed.dep_importance = Feed.Dep_essential) in

      (* Dependencies on commands *)
      let require_command name =
        (* What about optional command dependencies? Looks like the Python doesn't handle that either... *)
        let candidates = cache#lookup (Some name, dep.Feed.dep_iface, false) in
        S.implies sat user_var (candidates#get_vars ()) in
      List.iter require_command dep.Feed.dep_required_commands;

      (* Restrictions on the candidates *)
      let meets_restriction impl = List.for_all (fun (_name, test) -> test impl) dep.Feed.dep_restrictions in
      let candidates = cache#lookup (None, dep.Feed.dep_iface, false) in
      let (pass, fail) = candidates#partition meets_restriction in

      if essential then (
        S.implies sat user_var pass     (* Must choose a suitable candidate *)
      ) else (
        ListLabels.iter fail ~f:(fun bad_impl ->
          (* If [user_var] is selected, don't select an incompatible version of the optional dependency.
             We don't need to do this explicitly in the [essential] case, because we must select a good
             version and we can't select two. *)
          S.implies sat user_var [S.neg bad_impl]
        )
      )
    )

  (* Add the implementations of an interface to the cache (called the first time we visit it). *)
  and make_impls (iface, source) =
    let match_source impl = Feed.is_source impl = source in
    let matching_impls = maybe_add_dummy @@ List.filter match_source @@ impl_provider#get_implementations iface in
    let vars = List.map (fun impl -> (S.add_variable sat (SolverData.ImplElem impl), impl)) matching_impls in
    let impl_clause = if List.length vars > 0 then Some (S.at_most_one sat @@ List.map fst vars) else None in
    let data = new impl_candidates impl_clause vars in
    (data, fun () ->
      (* Process dependencies *)
      ListLabels.iter vars ~f:(fun (impl_var, impl) ->
        process_deps impl_var impl.Feed.props.Feed.requires
      )
    )

  (* Initialise this cache entry (called the first time we request this key). *)
  and add_to_cache (command, iface, source) =
    match command with
    | None -> make_impls (iface, source)
    | Some command ->
        let impls = cache#lookup (None, iface, source) in
        let commands = impls#get_commands command in
        let make_provides_command (_impl, elem) =
          (** [var] will be true iff this <command> is selected. *)
          let var = S.add_variable sat (SolverData.CommandElem elem) in
          (var, elem) in
        let vars = List.map make_provides_command commands in
        let command_clause = if List.length vars > 0 then Some (S.at_most_one sat @@ List.map fst vars) else None in
        let data = new command_candidates command_clause vars in

        let process_commands () =
          let depend_on_impl (command_var, command) (impl_var, _command) =
            (* For each command, require that we select the corresponding implementation. *)
            S.implies sat command_var [impl_var];
            (* Process command-specific dependencies *)
            process_deps command_var command.Feed.command_requires;
          in
          List.iter2 depend_on_impl vars commands in

        (data, process_commands) in

  (* Can't work out how to set these in the constructor call, so do it here instead. *)
  cache#set_maker add_to_cache;

  (* This recursively builds the whole problem up. *)
  let candidates = cache#lookup root_req in
  S.at_least_one sat @@ candidates#get_vars ();          (* Must get what we came for! *)

  (* Setup done; lock to prevent accidents *)
  let locked _ = failwith "building done" in
  cache#set_maker locked;

  (* Run the solve *)

  let decider () =
    (* Walk the current solution, depth-first, looking for the first undecided interface.
       Then try the most preferred implementation of it that hasn't been ruled out. *)
    let rec find_undecided req =
      let candidates = cache#lookup req in
      match candidates#get_state sat with
      | Unselected -> None
      | Undecided lit -> Some lit
      | Selected deps ->
          (* We've already selected a candidate for this component. Now check its dependencies. *)

          let check_dep dep =
            if dep.Feed.dep_importance = Feed.Dep_restricts then (
              (* Restrictions don't express that we do or don't want the
                 dependency, so skip them here. If someone else needs this,
                 we'll handle it when we get to them.
                 If noone wants it, it will be set to unselected at the end. *)
              None
            ) else (
              let dep_iface = dep.Feed.dep_iface in
              match find_undecided (None, dep_iface, false) with
              | Some lit -> Some lit
              | None ->
                  (* Command dependencies next *)
                  let check_command_dep name = find_undecided (Some name, dep_iface, false) in
                  Support.Utils.first_match check_command_dep dep.Feed.dep_required_commands
            )
            in
          match Support.Utils.first_match check_dep deps with
          | Some lit -> Some lit
          | None ->   (* All dependencies checked; now to the impl (if we're a <command>) *)
              match req with
              | (Some _command, iface, source) -> find_undecided (None, iface, source)
              | _ -> None     (* We're not a <command> *)
      in
    find_undecided root_req in

  (* Build the results object *)

  let get_selected_impl impl_clause =
    match impl_clause with
    | None -> None
    | Some impl_clause ->
        match S.get_selected impl_clause with
        | Some selected_lit -> (
            match (S.get_varinfo_for_lit sat selected_lit).S.obj with
            | SolverData.ImplElem impl -> Some impl
            | _ -> assert false
        )
        | None -> None in

  match S.run_solver sat decider with
  | None -> None
  | Some _solution ->
      Some (
      object
        (** Create a <selections> document from the result of a solve. *)
        method get_selections () =
          let root = ZI.make_root "selections" in
          root.Qdom.attrs <- [(("", "interface"), requirements.Requirements.interface_uri)];
          let () = match requirements.Requirements.command with
            | None -> ()
            | Some command ->
                root.Qdom.attrs <- (("", "command"), command) :: root.Qdom.attrs in

          (* For each implementation, remember which commands we need. *)
          let commands_needed = Hashtbl.create 10 in
          let check_command (command_name, iface, _source) _command =
            match command_name with
            | None -> ()
            | Some name -> Hashtbl.add commands_needed iface name in
          cache#iter check_command;

          let add_impl (command, iface, _source) impls : unit =
            if command = None then (
              let impl_clause = impls#get_clause () in
              match get_selected_impl impl_clause with
              | None -> ()      (* This interface wasn't used *)
              | Some impl ->
                  let sel = ZI.insert_first "selection" root in
                  if impl == dummy_impl then (
                    sel.Qdom.attrs <- [
                      (("", "interface"), iface);
                    ];
                  ) else (
                    sel.Qdom.attrs <- [
                      (("", "interface"), iface);
                      (("", "id"), (Feed.get_attr_ex Feed.attr_id impl));
                      (("", "version"), (Feed.get_attr_ex Feed.attr_version impl));
                    ];
                    let commands = Hashtbl.find_all commands_needed iface in
                    let add_command name =
                      let command = (Feed.get_command impl name).Feed.command_qdom in
                      let not_restricts elem = ZI.tag elem <> Some "restricts" in
                      let command = {command with Qdom.child_nodes = List.filter not_restricts command.Qdom.child_nodes} in
                      Qdom.prepend_child (Qdom.import_node command sel.Qdom.doc) sel in
                    List.iter add_command commands;

                    let copy_elem elem = Qdom.prepend_child (Qdom.import_node elem sel.Qdom.doc) sel in
                    List.iter copy_elem impl.Feed.props.Feed.bindings;
                    ListLabels.iter impl.Feed.props.Feed.requires ~f:(fun dep ->
                      if dep.Feed.dep_importance <> Feed.Dep_restricts then
                        copy_elem (dep.Feed.dep_qdom)
                    );

                    (* TODO: copy attrs *)

                    ZI.iter_with_name impl.Feed.qdom "manifest-digest" ~f:copy_elem
                  )
            )
            in
          cache#iter add_impl;
          root
      end
  )

class type impl_provider =
  object
    (** Return all the implementations of this interface (including from feeds).
        Most preferred implementations should come first. *)
    method get_implementations : iface_uri -> Feed.implementation list
  end

class sat_solver (impl_provider : impl_provider) =
  object (_ : #solver)
    method solve requirements =
      match solve_for impl_provider requirements ~closest_match:false with
      | Some result -> (true, result)
      | None ->
          match solve_for impl_provider requirements ~closest_match:true with
          | Some result -> (false, result)
          | None -> failwith "No solution, even with closest_match!"
  end
