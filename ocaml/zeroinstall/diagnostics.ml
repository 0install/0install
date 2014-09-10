(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Explaining why a solve failed or gave an unexpected answer. *)

open General
open Support.Common
module Qdom = Support.Qdom
module FeedAttr = Constants.FeedAttr

module U = Support.Utils

module RoleMap = Solver.RoleMap

let spf = Printf.sprintf

(* Why a particular implementation was rejected. This could be because the impl_provider rejected it,
   or because it conflicts with something else in the example (partial) solution. *)
type rejection_reason = [
  | Impl_provider.rejection
  | `FailsRestriction of Impl.restriction
  | `DepFailsRestriction of Impl.dependency * Impl.restriction
  | `MachineGroupConflict of Impl.impl_type Impl.t
  | `ConflictsInterface of iface_uri
  | `MissingCommand of string
  | `DiagnosticsFailure of string
]

type note =
  | UserRequested of Impl.restriction
  | ReplacesConflict of iface_uri
  | ReplacedByConflict of iface_uri
  | Restricts of iface_uri * Impl.generic_implementation * Impl.restriction list
  | RequiresCommand of iface_uri * Impl.generic_implementation * string
  | NoCandidates

let format_restrictions r = String.concat ", " (List.map (fun r -> r#to_string) r)
let format_version impl = Versions.format_version impl.Impl.parsed_version

let describe_problem impl = function
  | #Impl_provider.rejection as p -> Impl_provider.describe_problem impl p
  | `FailsRestriction r -> "Incompatible with restriction: " ^ r#to_string
  | `DepFailsRestriction (dep, restriction) -> spf "Requires %s %s" dep.Impl.dep_iface (format_restrictions [restriction])
  | `MachineGroupConflict other_impl ->
      let this_arch = default "BUG" impl.Impl.machine in
      let other_name = Impl.get_attr_ex FeedAttr.from_feed other_impl in
      let other_arch = default "BUG" other_impl.Impl.machine in
      spf "Can't use %s with selection of %s (%s)" this_arch other_name other_arch
  | `ConflictsInterface other_iface -> spf "Conflicts with %s" other_iface
  | `MissingCommand command -> spf "No %s command" command
  | `DiagnosticsFailure msg -> spf "Reason for rejection unknown: %s" msg

(* Add a textual description of this component's report to [buf]. *)
let format_report buf (iface_uri, _source) component =
  let prefix = ref "- " in

  let add fmt =
    let do_add msg = Buffer.add_string buf !prefix; Buffer.add_string buf msg in
    Printf.ksprintf do_add fmt in

  let name_impl impl = Impl.get_attr_ex FeedAttr.id impl in

  let () = match component#impl with
    | Some sel -> add "%s -> %s (%s)" iface_uri (format_version sel) (name_impl sel)
    | None -> add "%s -> (problem)" iface_uri in

  prefix := "\n    ";

  let show_rejections rejected =
    prefix := "\n      ";
    let by_version (a, _) (b, _) = Impl.(compare b.parsed_version a.parsed_version) in
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
    | ReplacesConflict old -> add "Replaces (and therefore conflicts with) %s" old
    | ReplacedByConflict replacement -> add "Replaced by (and therefore conflicts with) %s" replacement
    | Restricts (other_iface, impl, r) ->
        add "%s %s requires %s" other_iface (format_version impl) (format_restrictions r)
    | RequiresCommand (other_iface, impl, command) ->
        add "%s %s requires '%s' command" other_iface (format_version impl) command
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
class component candidates (diagnostics:string Lazy.t) (selected_impl:Impl.generic_implementation option) =
  let {Impl_provider.impls = orig_good; Impl_provider.rejects = orig_bad; Impl_provider.replacement} = candidates in
  (* orig_good is all the implementations passed to the SAT solver (these are the
     ones with a compatible OS, CPU, etc). They are sorted most desirable first. *)
  object (self)
    val mutable notes = []
    val mutable good = orig_good
    val mutable bad = (orig_bad :> (Impl.generic_implementation * rejection_reason) list)

    method note (note:note) = notes <- note :: notes

    (* Call [get_problem impl] on each good impl. If a problem is returned, move [impl] to [bad_impls]. *)
    method filter_impls get_problem =
      let old_good = List.rev good in
      good <- [];
      ListLabels.iter old_good ~f:(fun impl ->
        match get_problem impl with
        | None -> good <- impl :: good
        | Some problem -> bad <- (impl, problem) :: bad
      )

    (* Remove from [good_impls] anything that fails to meet these restrictions.
       Add removed items to [bad_impls], along with the cause. *)
    method apply_restrictions restrictions =
      ListLabels.iter restrictions ~f:(fun r ->
        self#filter_impls (fun impl ->
          if r#meets_restriction impl then None
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

let get_machine_group impl =
  match impl.Impl.machine with
  | None -> None
  | Some "src" -> None
  | Some m -> Some (Arch.get_machine_group m)

let find_component key report =
  try Some (RoleMap.find key report)
  with Not_found -> None

let find_component_ex key report =
  match find_component key report with
  | Some c -> c
  | None -> raise_safe "Can't find component %s!" (fst key)

(* Did any dependency of [impl] prevent it being selected?
   This can only happen if a component conflicts with something more important
   than itself (otherwise, we'd select something in [impl]'s interface and
   complain about the dependency instead).

   e.g. A depends on B and C. B and C both depend on D.
   C1 conflicts with D1. The depth-first priority order means we give priority
   to {A1, B1, D1}. Then we can't choose C1 because we prefer to keep D1. *)
let get_dependency_problem report impl =
  let check_dep dep =
    match find_component (dep.Impl.dep_iface, false) report with
    | None -> None      (* Not in the selections => can't be part of a conflict *)
    | Some required_component ->
        match required_component#impl with
        | None -> None  (* Dummy selection can't cause a conflict *)
        | Some dep_impl ->
            let check_restriction r =
              if r#meets_restriction dep_impl then None
              else Some (`DepFailsRestriction (dep, r)) in
            U.first_match check_restriction dep.Impl.dep_restrictions in
  U.first_match check_dep impl.Impl.props.Impl.requires

(** A selected component has [dep] as a dependency. Use this to explain why some implementations
    of the required interface were rejected. *)
let examine_dep requiring_iface requiring_impl report dep =
  let other_iface = dep.Impl.dep_iface in
  match find_component (other_iface, false) report with
  | None -> ()
  | Some required_component ->
      if dep.Impl.dep_restrictions <> [] then (
        (* Report the restriction *)
        required_component#note (Restricts (requiring_iface, requiring_impl, dep.Impl.dep_restrictions));

        (* Remove implementations incompatible with the other selections *)
        required_component#apply_restrictions dep.Impl.dep_restrictions
      );

      ListLabels.iter dep.Impl.dep_required_commands ~f:(fun command ->
        required_component#note (RequiresCommand (requiring_iface, requiring_impl, command));
        required_component#filter_impls (fun impl ->
          if StringMap.mem command Impl.(impl.props.commands) then None
          else Some (`MissingCommand command)
        )
      )

(* Find all restrictions that are in play and affect this interface *)
let examine_selection report (iface_uri, source) component =
  (* Note any conflicts caused by <replaced-by> elements *)
  let () =
    match component#replacement with
    | Some replacement when RoleMap.mem (replacement, source) report -> (
        component#note (ReplacedByConflict replacement);
        component#reject_all (`ConflictsInterface replacement);
        match find_component (replacement, source) report with
        | Some replacement_component ->
            replacement_component#note (ReplacesConflict iface_uri);
            replacement_component#reject_all (`ConflictsInterface iface_uri)
        | None -> ()
    )
    | _ -> () in

  match component#impl with
  | Some our_impl ->
      (* For each dependency of our selected impl, explain why it rejected impls in the dependency's interface. *)
      List.iter (examine_dep iface_uri our_impl report) our_impl.Impl.props.Impl.requires
  | None ->
      (* For each of our remaining unrejected impls, check whether a dependency prevented its selection. *)
      component#filter_impls (get_dependency_problem report)

let reject_if_unselected _key component =
  if component#impl = None then (
    component#reject_all (`DiagnosticsFailure (Lazy.force component#diagnostics));
    component#note NoCandidates;
  )

(* Check for user-supplied restrictions *)
let examine_extra_restrictions report extra_restrictions =
  let process ~source iface restriction =
    try
      match find_component (iface, source) report with
      | None -> ()
      | Some component ->
          component#note (UserRequested restriction);
          component#apply_restrictions [restriction]
    with Not_found -> () in

  StringMap.iter (process ~source:false) extra_restrictions;
  StringMap.iter (process ~source:true) extra_restrictions

(** If we wanted a command on the root, add that as a restriction. *)
let process_root_req report = function
  | Solver.ReqCommand (root_command, root_iface, source) ->
      let component = find_component_ex (root_iface, source) report in
      component#filter_impls (fun impl ->
        if StringMap.mem root_command Impl.(impl.props.commands) then None
        else Some (`MissingCommand root_command)
      )
  | Solver.ReqIface _ -> ()

(** Find an implementation which requires a machine group. Use this to
    explain the rejection of all implementations requiring other groups. *)
exception Found of (Impl.generic_implementation * Arch.machine_group)
let check_machine_groups report =
  let check _key compoment =
    match compoment#impl with
    | None -> ()
    | Some impl ->
        match get_machine_group impl with
        | None -> ()
        | Some group -> raise (Found (impl, group)) in

  try RoleMap.iter check report
  with Found (example_impl, example_group) ->
    let filter _key component = component#filter_impls (fun impl ->
      match get_machine_group impl with
      | Some group when group <> example_group -> Some (`MachineGroupConflict example_impl)
      | _ -> None
    ) in
    RoleMap.iter filter report

let get_failure_report (result:Solver.result) : component RoleMap.t =
  let impl_provider = result#impl_provider in
  let impls = result#raw_selections in
  let root_req = result#requirements in

  let report =
    let get_selected ((iface, source) as key) impl =
      let diagnostics = lazy (result#explain key) in
      let impl = if impl.Impl.parsed_version = Versions.dummy then None else Some impl in
      let impl_candidates = impl_provider#get_implementations iface ~source in
      new component impl_candidates diagnostics impl in
    Solver.RoleMap.mapi get_selected impls in

  process_root_req report root_req;
  examine_extra_restrictions report impl_provider#extra_restrictions;
  check_machine_groups report;
  RoleMap.iter (examine_selection report) report;
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
