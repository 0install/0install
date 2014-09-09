(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Explaining why a solve failed or gave an unexpected answer. *)

open General
open Support.Common
module Qdom = Support.Qdom
module FeedAttr = Constants.FeedAttr

module U = Support.Utils

module Model = Solver.Model
module RoleMap = Solver.RoleMap

let spf = Printf.sprintf

(* Why a particular implementation was rejected. This could be because the model rejected it,
   or because it conflicts with something else in the example (partial) solution. *)
type rejection_reason = [
  | `Model_rejection of Model.rejection
  | `FailsRestriction of Model.restriction
  | `DepFailsRestriction of Model.dependency * Model.restriction
  | `MachineGroupConflict of Model.Role.t * Model.impl
  | `ConflictsRole of Model.Role.t
  | `MissingCommand of Model.command_name
  | `DiagnosticsFailure of string
]

type note =
  | UserRequested of Model.restriction
  | ReplacesConflict of Model.Role.t
  | ReplacedByConflict of Model.Role.t
  | Restricts of Model.Role.t * Model.impl * Model.restriction list
  | RequiresCommand of Model.Role.t * Model.impl * Model.command_name
  | NoCandidates

let format_restrictions r = String.concat ", " (List.map Model.string_of_restriction r)
let format_version impl = Versions.format_version (Model.version impl)

let describe_problem impl = function
  | `Model_rejection r -> Model.describe_problem impl r
  | `FailsRestriction r -> "Incompatible with restriction: " ^ Model.string_of_restriction r
  | `DepFailsRestriction (dep, restriction) ->
      spf "Requires %s %s" (Model.Role.to_string dep.Model.dep_role) (format_restrictions [restriction])
  | `MachineGroupConflict (other_role, other_impl) ->
      spf "Can't use %s with selection of %s (%s)"
        (Model.format_machine impl)
        (Model.Role.to_string other_role)
        (Model.format_machine other_impl)
  | `ConflictsRole other_role -> spf "Conflicts with %s" (Model.Role.to_string other_role)
  | `MissingCommand command -> spf "No %s command" (command : Model.command_name :> string)
  | `DiagnosticsFailure msg -> spf "Reason for rejection unknown: %s" msg

(* Add a textual description of this component's report to [buf]. *)
let format_report buf role component =
  let prefix = ref "- " in

  let add fmt =
    let do_add msg = Buffer.add_string buf !prefix; Buffer.add_string buf msg in
    Printf.ksprintf do_add fmt in

  let name_impl impl = Model.id_of_impl impl in

  let () = match component#impl with
    | Some sel -> add "%s -> %s (%s)" (Model.Role.to_string role) (format_version sel) (name_impl sel)
    | None -> add "%s -> (problem)" (Model.Role.to_string role) in

  prefix := "\n    ";

  let show_rejections rejected =
    prefix := "\n      ";
    let by_version (a, _) (b, _) = Model.(compare (version b) (version a)) in
    let rejected = List.sort by_version rejected in
    let i = ref 0 in
    let () =
      try
        ListLabels.iter rejected ~f:(fun (impl, problem) ->
          if !i = 5 && not Support.Logging.(will_log Debug) then (add "..."; raise Exit);
          add "%s (%s): %s" (name_impl impl) (format_version impl) (describe_problem impl problem);
          i := !i + 1
        );
      with Exit -> () in
    prefix := "\n    " in

  ListLabels.iter component#notes ~f:(function
    | UserRequested r -> add "User requested %s" (format_restrictions [r])
    | ReplacesConflict old -> add "Replaces (and therefore conflicts with) %s" (Model.Role.to_string old)
    | ReplacedByConflict replacement -> add "Replaced by (and therefore conflicts with) %s" (Model.Role.to_string replacement)
    | Restricts (other_role, impl, r) ->
        add "%s %s requires %s" (Model.Role.to_string other_role) (format_version impl) (format_restrictions r)
    | RequiresCommand (other_role, impl, command) ->
        add "%s %s requires '%s' command" (Model.Role.to_string other_role) (format_version impl) (command :> string)
    | NoCandidates ->
        if component#original_good = [] then (
          if component#original_bad = [] then (
            add "No known implementations at all"
          ) else (
            add "No usable implementations:"
          )
        ) else (
          add "Rejected candidates:"
        );
        show_rejections (component#bad)
  );

  Buffer.add_string buf "\n"

(** Represents a single interface in the example (failed) selections produced by the solver.
    It partitions the implementations into good and bad based (initially) on the split from the
    impl_provider. As we explore the example selections, we further filter the candidates.
    [candidates] is the result from the impl_provider.
    [impl] is the selected implementation, or [None] if we chose [dummy_impl].
    [diagnostics] can be used to produce diagnostics as a last resort. *)
class component (candidates, orig_bad) (diagnostics:string Lazy.t) (selected_impl:Model.impl option) =
  let {Model.impls = orig_good; Model.replacement} = candidates in
  let orig_bad : (Model.impl * rejection_reason) list =
    List.map (fun (impl, reason) -> (impl, `Model_rejection reason)) orig_bad in
  (* orig_good is all the implementations passed to the SAT solver (these are the
     ones with a compatible OS, CPU, etc). They are sorted most desirable first. *)
  object (self)
    val mutable notes = []
    val mutable good = orig_good
    val mutable bad = orig_bad

    method note (note:note) = notes <- note :: notes

    (* Call [get_problem impl] on each good impl. If a problem is returned, move [impl] to [bad_impls]. *)
    method filter_impls get_problem =
      let old_good = List.rev good in
      good <- [];
      old_good |> List.iter (fun impl ->
        match get_problem impl with
        | None -> good <- impl :: good
        | Some problem -> bad <- (impl, problem) :: bad
      )

    (* Remove from [good_impls] anything that fails to meet these restrictions.
       Add removed items to [bad_impls], along with the cause. *)
    method apply_restrictions restrictions =
      ListLabels.iter restrictions ~f:(fun r ->
        self#filter_impls (fun impl ->
          if Model.meets_restriction impl r then None
          else Some (`FailsRestriction r)
        )
      )

    method reject_all reason =
      bad <- List.map (fun impl -> (impl, reason)) good @ bad;
      good <- []

    method diagnostics = diagnostics
    method replacement = replacement
    method impl = selected_impl
    method notes = List.rev notes

    method good = good
    method bad = bad

    method original_good = orig_good
    method original_bad = orig_bad
  end

let find_component key report =
  try Some (RoleMap.find key report)
  with Not_found -> None

let find_component_ex role report =
  match find_component role report with
  | Some c -> c
  | None -> raise_safe "Can't find component %s!" (Model.Role.to_string role)

(* Did any dependency of [impl] prevent it being selected?
   This can only happen if a component conflicts with something more important
   than itself (otherwise, we'd select something in [impl]'s interface and
   complain about the dependency instead).

   e.g. A depends on B and C. B and C both depend on D.
   C1 conflicts with D1. The depth-first priority order means we give priority
   to {A1, B1, D1}. Then we can't choose C1 because we prefer to keep D1. *)
let get_dependency_problem model report impl =
  let check_dep dep =
    match find_component dep.Model.dep_role report with
    | None -> None      (* Not in the selections => can't be part of a conflict *)
    | Some required_component ->
        match required_component#impl with
        | None -> None  (* Dummy selection can't cause a conflict *)
        | Some dep_impl ->
            let check_restriction r =
              if Model.meets_restriction dep_impl r then None
              else Some (`DepFailsRestriction (dep, r)) in
            U.first_match check_restriction dep.Model.dep_restrictions in
  let deps, commands_needed = Model.requires model impl in
  commands_needed |> U.first_match (fun command ->
    if Model.get_command impl command <> None then None
    else Some (`MissingCommand command : rejection_reason)
  )
  |> function
  | Some _ as r -> r
  | None -> U.first_match check_dep deps

(** A selected component has [dep] as a dependency. Use this to explain why some implementations
    of the required interface were rejected. *)
let examine_dep requiring_role requiring_impl report dep =
  let {Model.dep_role = other_role; dep_restrictions; dep_importance = _; dep_required_commands} = dep in
  match find_component other_role report with
  | None -> ()
  | Some required_component ->
      if dep_restrictions <> [] then (
        (* Report the restriction *)
        required_component#note (Restricts (requiring_role, requiring_impl, dep_restrictions));

        (* Remove implementations incompatible with the other selections *)
        required_component#apply_restrictions dep_restrictions
      );

      dep_required_commands |> List.iter (fun command ->
        required_component#note (RequiresCommand (requiring_role, requiring_impl, command));
        required_component#filter_impls (fun impl ->
          if Model.get_command impl command <> None then None
          else Some (`MissingCommand command)
        )
      )

(* Find all restrictions that are in play and affect this interface *)
let examine_selection model report role component =
  (* Note any conflicts caused by <replaced-by> elements *)
  let () =
    match component#replacement with
    | Some replacement when RoleMap.mem replacement report -> (
        component#note (ReplacedByConflict replacement);
        component#reject_all (`ConflictsRole replacement);
        match find_component replacement report with
        | Some replacement_component ->
            replacement_component#note (ReplacesConflict role);
            replacement_component#reject_all (`ConflictsRole role)
        | None -> ()
    )
    | _ -> () in

  match component#impl with
  | Some our_impl ->
      (* For each dependency of our selected impl, explain why it rejected impls in the dependency's interface. *)
      let deps, _commands_needed = Model.requires model our_impl in
      (* We can ignore [commands_needed] here because we obviously were selected. *)
      List.iter (examine_dep role our_impl report) deps
  | None ->
      (* For each of our remaining unrejected impls, check whether a dependency prevented its selection. *)
      component#filter_impls (get_dependency_problem model report)

let reject_if_unselected _key component =
  if component#impl = None then (
    component#reject_all (`DiagnosticsFailure (Lazy.force component#diagnostics));
    component#note NoCandidates;
  )

(* Check for user-supplied restrictions *)
let examine_extra_restrictions model report =
  report |> RoleMap.iter (fun role component ->
    Model.user_restrictions model role |> if_some (fun restriction ->
      component#note (UserRequested restriction);
      component#apply_restrictions [restriction]
    )
  )

(** If we wanted a command on the root, add that as a restriction. *)
let process_root_req report = function
  | Model.ReqCommand (root_command, root_role) ->
      let component = find_component_ex root_role report in
      component#filter_impls (fun impl ->
        if Model.get_command impl root_command <> None then None
        else Some (`MissingCommand root_command)
      )
  | Model.ReqRole _ -> ()

(** Find an implementation which requires a machine group. Use this to
    explain the rejection of all implementations requiring other groups. *)
exception Found of (Model.Role.t * Model.impl * Arch.machine_group)
let check_machine_groups report =
  let check role compoment =
    match compoment#impl with
    | None -> ()
    | Some impl ->
        match Model.machine impl with
        | None -> ()
        | Some group -> raise (Found (role, impl, group)) in

  try RoleMap.iter check report
  with Found (example_role, example_impl, example_group) ->
    let filter _key component = component#filter_impls (fun impl ->
      match Model.machine impl with
      | Some group when group <> example_group -> Some (`MachineGroupConflict (example_role, example_impl))
      | _ -> None
    ) in
    RoleMap.iter filter report

let get_failure_report result : component RoleMap.t =
  let model = Solver.model result in
  let impls = Solver.raw_selections result in
  let root_req = Solver.requirements result in

  let report =
    let get_selected role impl =
      let diagnostics = lazy (Solver.explain result role) in
      let impl = if impl == Model.dummy_impl then None else Some impl in
      let impl_candidates = Model.implementations model role in
      let rejects = Model.rejects model role in
      new component (impl_candidates, rejects) diagnostics impl in
    RoleMap.mapi get_selected impls in

  process_root_req report root_req;
  examine_extra_restrictions model report;
  check_machine_groups report;
  RoleMap.iter (examine_selection model report) report;
  RoleMap.iter reject_if_unselected report;

  report

(** Return a message explaining why the solve failed. *)
let get_failure_reason config result : string =
  let reasons = get_failure_report result in

  let buf = Buffer.create 1000 in
  Buffer.add_string buf "Can't find all required implementations:\n";
  RoleMap.iter (format_report buf) reasons;
  if config.network_use = Offline then
    Buffer.add_string buf "Note: 0install is in off-line mode\n";
  Buffer.sub buf 0 (Buffer.length buf - 1)
