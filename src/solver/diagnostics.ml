(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Explaining why a solve failed or gave an unexpected answer. *)

module List = Solver_core.List
module Option = Solver_core.Option

let pf = Format.fprintf

module Make (Results : S.SOLVER_RESULT) = struct
  module Model = Results.Input
  module RoleMap = Results.RoleMap

  let format_role = Model.Role.pp
  let format_version f v = Format.pp_print_string f (Model.format_version v)

  module Note = struct
    (* Why a particular implementation was rejected. This could be because the model rejected it,
       or because it conflicts with something else in the example (partial) solution. *)
    type rejection_reason = [
      | `Model_rejection of Model.rejection
      | `FailsRestriction of Model.restriction
      | `DepFailsRestriction of Model.dependency * Model.restriction
      | `MachineGroupConflict of Model.Role.t * Model.impl
      | `ClassConflict of Model.Role.t * Model.conflict_class
      | `ConflictsRole of Model.Role.t
      | `MissingCommand of Model.command_name
      | `DiagnosticsFailure of string
    ]

    type t =
      | UserRequested of Model.restriction
      | ReplacesConflict of Model.Role.t
      | ReplacedByConflict of Model.Role.t
      | Restricts of Model.Role.t * Model.impl * Model.restriction list
      | RequiresCommand of Model.Role.t * Model.impl * Model.command_name
      | Feed_problem of string
      | NoCandidates of {
          reason : [`No_candidates | `No_usable_candidates | `Rejected_candidates];
          rejects : (Model.impl * rejection_reason) list;
        }

    let format_restrictions r = String.concat ", " (List.map Model.string_of_restriction r)

    let describe_problem impl f : rejection_reason -> unit = function
      | `Model_rejection r -> Format.pp_print_string f (Model.describe_problem impl r)
      | `FailsRestriction r -> pf f "Incompatible with restriction: %s" (Model.string_of_restriction r)
      | `DepFailsRestriction (dep, restriction) ->
          let dep_info = Model.dep_info dep in
          pf f "Requires %a %s" format_role dep_info.Model.dep_role (format_restrictions [restriction])
      | `MachineGroupConflict (other_role, other_impl) ->
          pf f "Can't use %s with selection of %a (%s)"
            (Model.format_machine impl)
            format_role other_role
            (Model.format_machine other_impl)
      | `ClassConflict (other_role, cl) ->
          pf f "In same conflict class (%s) as %a"
            (cl :> string)
            format_role other_role
      | `ConflictsRole other_role -> pf f "Conflicts with %a" format_role other_role
      | `MissingCommand command -> pf f "No %s command" (command : Model.command_name :> string)
      | `DiagnosticsFailure msg -> pf f "Reason for rejection unknown: %s" msg

    let show_rejections ~verbose f rejected =
      let by_version (a, _) (b, _) = Model.compare_version b a in
      let rejected = List.sort by_version rejected in
      let rec aux i = function
        | [] -> ()
        | _ when i = 5 && not verbose -> pf f "@,..."
        | (impl, problem) :: xs ->
          pf f "@,%s (%a): %a" (Model.id_of_impl impl) format_version impl (describe_problem impl) problem;
          aux (i + 1) xs
      in
      aux 0 rejected

    let pp ~verbose f = function
      | UserRequested r -> pf f "User requested %s" (format_restrictions [r])
      | ReplacesConflict old -> pf f "Replaces (and therefore conflicts with) %a" format_role old
      | ReplacedByConflict replacement -> pf f "Replaced by (and therefore conflicts with) %a" format_role replacement
      | Restricts (other_role, impl, r) ->
        pf f "%a %a requires %s" format_role other_role format_version impl (format_restrictions r)
      | RequiresCommand (other_role, impl, command) ->
        pf f "%a %a requires '%s' command" format_role other_role format_version impl (command :> string)
      | Feed_problem msg -> pf f "%s" msg
      | NoCandidates { reason; rejects } ->
        let msg =
          match reason with
          | `No_candidates -> "No known implementations at all"
          | `No_usable_candidates -> "No usable implementations:"
          | `Rejected_candidates -> "Rejected candidates:"
        in
        pf f "@[<v2>%s%a@]" msg (show_rejections ~verbose) rejects
  end

  (** Represents a single interface in the example (failed) selections produced by the solver.
      It partitions the implementations into good and bad based (initially) on the split from the
      impl_provider. As we explore the example selections, we further filter the candidates. *)
  module Component = struct
    type t = {
      role : Model.Role.t;
      replacement : Model.Role.t option;
      diagnostics : string Lazy.t;
      selected_impl : Model.impl option;
      selected_commands : Model.command_name list;
      (* orig_good is all the implementations passed to the SAT solver (these are the
         ones with a compatible OS, CPU, etc). They are sorted most desirable first. *)
      orig_good : Model.impl list;
      orig_bad : (Model.impl * Model.rejection) list;
      mutable good : Model.impl list;
      mutable bad : (Model.impl * Note.rejection_reason) list;
      mutable notes : Note.t list;
    }

    (* Initialise a new component.
       @param candidates is the result from the impl_provider.
       @param selected_impl is the selected implementation, or [None] if we chose [dummy_impl].
       @param diagnostics can be used to produce diagnostics as a last resort. *)
    let create
        ~role
        (candidates, orig_bad, feed_problems)
        (diagnostics:string Lazy.t)
        (selected_impl:Model.impl option)
        (selected_commands:Model.command_name list) =
      let {Model.impls; Model.replacement} = candidates in
      let notes = List.map (fun x -> Note.Feed_problem x) feed_problems in
      {
        role;
        replacement;
        orig_good = impls;
        orig_bad;
        good = impls;
        bad = List.map (fun (impl, reason) -> (impl, `Model_rejection reason)) orig_bad;
        notes; diagnostics; selected_impl; selected_commands
      }

    let note t note = t.notes <- note :: t.notes
    let notes t = List.rev t.notes

    (* Call [get_problem impl] on each good impl. If a problem is returned, move [impl] to [bad_impls]. *)
    let filter_impls t get_problem =
      let old_good = List.rev t.good in
      t.good <- [];
      old_good |> List.iter (fun impl ->
          match get_problem impl with
          | None -> t.good <- impl :: t.good
          | Some problem -> t.bad <- (impl, problem) :: t.bad
        )

    (* Remove from [good_impls] anything that fails to meet these restrictions.
       Add removed items to [bad_impls], along with the cause. *)
    let apply_restrictions t restrictions =
      restrictions |> List.iter (fun r ->
          filter_impls t (fun impl ->
              if Model.meets_restriction impl r then None
              else Some (`FailsRestriction r)
            )
        )

    let reject_all t reason =
      t.bad <- List.map (fun impl -> (impl, reason)) t.good @ t.bad;
      t.good <- []

    let replacement t = t.replacement
    let selected_impl t = t.selected_impl
    let selected_commands t = t.selected_commands

    let finalise t =
      if t.selected_impl = None then (
        reject_all t (`DiagnosticsFailure (Lazy.force t.diagnostics));
        let reason =
          if t.orig_good = [] then (
            if t.orig_bad = [] then `No_candidates
            else `No_usable_candidates
          ) else `Rejected_candidates
        in
        note t @@ NoCandidates { reason; rejects = t.bad }
      )

    let pp_notes ~verbose f t =
      match notes t with
      | [] -> ()
      | notes -> pf f "@,%a" Format.(pp_print_list ~pp_sep:pp_print_cut (Note.pp ~verbose)) notes

    let pp_outcome f t =
      match t.selected_impl with
      | Some sel -> pf f "%a (%s)" format_version sel (Model.id_of_impl sel)
      | None -> Format.pp_print_string f "(problem)"

    (* Format a textual description of this component's report. *)
    let pp ~verbose f t =
      pf f "@[<v2>%a -> %a%a@]"
        format_role t.role
        pp_outcome t
        (pp_notes ~verbose) t
  end

  type t = Component.t RoleMap.t

  let find_component_ex role report =
    match RoleMap.find_opt role report with
    | Some c -> c
    | None -> failwith (Format.asprintf "Can't find component %a!" format_role role)

  (* Did any dependency of [impl] prevent it being selected?
     This can only happen if a component conflicts with something more important
     than itself (otherwise, we'd select something in [impl]'s interface and
     complain about the dependency instead).

     e.g. A depends on B and C. B and C both depend on D.
     C1 conflicts with D1. The depth-first priority order means we give priority
     to {A1, B1, D1}. Then we can't choose C1 because we prefer to keep D1. *)
  let get_dependency_problem role report impl =
    let check_dep dep =
      let dep_info = Model.dep_info dep in
      match RoleMap.find_opt dep_info.Model.dep_role report with
      | None -> None      (* Not in the selections => can't be part of a conflict *)
      | Some required_component ->
          match Component.selected_impl required_component with
          | None -> None  (* Dummy selection can't cause a conflict *)
          | Some dep_impl ->
              let check_restriction r =
                if Model.meets_restriction dep_impl r then None
                else Some (`DepFailsRestriction (dep, r)) in
              List.first_match check_restriction (Model.restrictions dep) in
    let deps, commands_needed = Model.requires role impl in
    commands_needed |> List.first_match (fun command ->
      if Model.get_command impl command <> None then None
      else Some (`MissingCommand command : Note.rejection_reason)
    )
    |> function
    | Some _ as r -> r
    | None -> List.first_match check_dep deps

  (** A selected component has [dep] as a dependency. Use this to explain why some implementations
      of the required interface were rejected. *)
  let examine_dep requiring_role requiring_impl report dep =
    let {Model.dep_role = other_role; dep_importance = _; dep_required_commands} = Model.dep_info dep in
    match RoleMap.find_opt other_role report with
    | None -> ()
    | Some required_component ->
        let dep_restrictions = Model.restrictions dep in
        if dep_restrictions <> [] then (
          (* Report the restriction *)
          Component.note required_component (Restricts (requiring_role, requiring_impl, dep_restrictions));

          (* Remove implementations incompatible with the other selections *)
          Component.apply_restrictions required_component dep_restrictions
        );

        dep_required_commands |> List.iter (fun command ->
          Component.note required_component (RequiresCommand (requiring_role, requiring_impl, command));
          Component.filter_impls required_component (fun impl ->
            if Model.get_command impl command <> None then None
            else Some (`MissingCommand command)
          )
        )

  (* Find all restrictions that are in play and affect this interface *)
  let examine_selection report role component =
    (* Note any conflicts caused by <replaced-by> elements *)
    let () =
      match Component.replacement component with
      | Some replacement when RoleMap.mem replacement report -> (
          Component.note component (ReplacedByConflict replacement);
          Component.reject_all component (`ConflictsRole replacement);
          match RoleMap.find_opt replacement report with
          | Some replacement_component ->
              Component.note replacement_component (ReplacesConflict role);
              Component.reject_all replacement_component (`ConflictsRole role)
          | None -> ()
      )
      | _ -> () in

    match Component.selected_impl component with
    | Some our_impl ->
        (* For each dependency of our selected impl, explain why it rejected impls in the dependency's interface. *)
        let deps, _commands_needed = Model.requires role our_impl in
        (* We can ignore [commands_needed] here because we obviously were selected. *)
        List.iter (examine_dep role our_impl report) deps;
        Component.selected_commands component |> List.iter (fun name ->
            match Model.get_command our_impl name with
            | None -> failwith "BUG: missing command!"    (* Can't happen - it's a "selected" command *)
            | Some command ->
              let deps, _commands_needed = Model.command_requires role command in
              List.iter (examine_dep role our_impl report) deps;
          )
    | None ->
        (* For each of our remaining unrejected impls, check whether a dependency prevented its selection. *)
        Component.filter_impls component (get_dependency_problem role report)

  (* Check for user-supplied restrictions *)
  let examine_extra_restrictions report =
    report |> RoleMap.iter (fun role component ->
      Model.user_restrictions role |> Option.iter (fun restriction ->
        Component.note component (UserRequested restriction);
        Component.apply_restrictions component [restriction]
      )
    )

  (** If we wanted a command on the root, add that as a restriction. *)
  let process_root_req report = function
    | {Model.command = Some root_command; role = root_role} ->
        let component = find_component_ex root_role report in
        Component.filter_impls component (fun impl ->
          if Model.get_command impl root_command <> None then None
          else Some (`MissingCommand root_command)
        )
    | _ -> ()

  (** Find an implementation which requires a machine group. Use this to
      explain the rejection of all implementations requiring other groups. *)
  exception Found of (Model.Role.t * Model.impl * Model.machine_group)
  let check_machine_groups report =
    let check role compoment =
      match Component.selected_impl compoment with
      | None -> ()
      | Some impl ->
          match Model.machine_group impl with
          | None -> ()
          | Some group -> raise (Found (role, impl, group)) in

    try RoleMap.iter check report
    with Found (example_role, example_impl, example_group) ->
      let filter _key component = Component.filter_impls component (fun impl ->
        match Model.machine_group impl with
        | Some group when group <> example_group -> Some (`MachineGroupConflict (example_role, example_impl))
        | _ -> None
      ) in
      RoleMap.iter filter report

  module Classes = Map.Make(struct
      type t = Model.conflict_class
      let compare = compare
    end)

  (** For each selected implementation with a conflict class, reject all candidates
      with the same class. *)
  let check_conflict_classes report =
    let classes =
      RoleMap.fold (fun role component acc ->
          match Component.selected_impl component with
          | None -> acc
          | Some impl -> Model.conflict_class impl |> List.fold_left (fun acc x -> Classes.add x role acc) acc
        ) report Classes.empty
    in
    report |> RoleMap.iter @@ fun role component ->
    Component.filter_impls component @@ fun impl ->
    let rec aux = function
      | [] -> None
      | cl :: cls ->
        match Classes.find_opt cl classes with
        | Some other_role when Model.Role.compare role other_role <> 0 -> Some (`ClassConflict (other_role, cl))
        | _ -> aux cls
    in
    aux (Model.conflict_class impl)

  let of_result result =
    let impls = Results.to_map result in
    let root_req = Results.requirements result in
    let report =
      let get_selected role sel =
        let impl = Results.unwrap sel in
        let diagnostics = lazy (Results.explain result role) in
        let impl = if impl == Model.dummy_impl then None else Some impl in
        let impl_candidates = Model.implementations role in
        let rejects, feed_problems = Model.rejects role in
        let selected_commands = Results.selected_commands sel in
        Component.create ~role (impl_candidates, rejects, feed_problems) diagnostics impl selected_commands in
      RoleMap.mapi get_selected impls
    in
    process_root_req report root_req;
    examine_extra_restrictions report;
    check_machine_groups report;
    check_conflict_classes report;
    RoleMap.iter (examine_selection report) report;
    RoleMap.iter (fun _ c -> Component.finalise c) report;
    report

  let pp_rolemap ~verbose f reasons =
    let pp_item f (_, c) = pf f "- @[%a@]" (Component.pp ~verbose) c in
    Format.(pp_print_list ~pp_sep:pp_print_cut) pp_item f (RoleMap.bindings reasons)

  (** Return a message explaining why the solve failed. *)
  let get_failure_reason ?(verbose=false) result =
    let reasons = of_result result in
    Format.asprintf "Can't find all required implementations:@\n@[<v0>%a@]" (pp_rolemap ~verbose) reasons
end
