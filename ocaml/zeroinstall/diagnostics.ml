(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Explaining why a solve failed or gave an unexpected answer. *)

open General
open Support.Common
module Qdom = Support.Qdom
module U = Support.Utils

module S = Solver.S

module SelMap = Map.Make (
  struct
    type t = (iface_uri * bool)
    let compare = compare
  end
)

let spf = Printf.sprintf

(* Why a particular implementation was rejected. This could be because the impl_provider rejected it,
   or because it conflicts with something else in the example (partial) solution. *)
type rejection_reason = [
  | Impl_provider.rejection
  | `FailsRestriction of Feed.restriction
  | `DepFailsRestriction of Feed.dependency * Feed.restriction
  | `MachineGroupConflict of Feed.implementation
  | `ConflictsInterface of iface_uri
  | `MissingCommand of string
  | `DiagnosticsFailure of string
]

type note =
  | UserRequested of Feed.restriction
  | ReplacesConflict of iface_uri
  | ReplacedByConflict of iface_uri
  | Restricts of iface_uri * Feed.implementation * Feed.restriction list
  | RequiresCommand of iface_uri * Feed.implementation * string
  | NoCandidates

let format_restrictions r = String.concat ", " (List.map (fun r -> r#to_string) r)
let format_version impl = Versions.format_version impl.Feed.parsed_version

let describe_problem impl = function
  | #Impl_provider.rejection as p -> Impl_provider.describe_problem impl p
  | `FailsRestriction r -> "Incompatible with restriction: " ^ r#to_string
  | `DepFailsRestriction (dep, restriction) -> spf "Requires %s %s" dep.Feed.dep_iface (format_restrictions [restriction])
  | `MachineGroupConflict other_impl ->
      let this_arch = default "BUG" impl.Feed.machine in
      let other_name = Feed.get_attr Feed.attr_from_feed other_impl in
      let other_arch = default "BUG" other_impl.Feed.machine in
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

  let name_impl impl = Feed.(get_attr attr_id impl) in

  let () = match component#impl with
    | Some sel -> add "%s -> %s (%s)" iface_uri (format_version sel) (name_impl sel)
    | None -> add "%s -> (problem)" iface_uri in

  prefix := "\n    ";

  let show_rejections rejected =
    prefix := "\n      ";
    let by_version (a, _) (b, _) = Feed.(compare b.parsed_version a.parsed_version) in
    let rejected = List.sort by_version rejected in
    let i = ref 0 in
    let () =
      try
        ListLabels.iter rejected ~f:(fun (impl, problem) ->
          if !i = 5 then (add "..."; raise Exit);
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
    [lit] is the SAT literal, which can be used to produce diagnostics as a last resort. *)
class component candidates (lit:S.lit) (selected_impl:Feed.implementation option) =
  let {Impl_provider.impls = orig_good; Impl_provider.rejects = orig_bad; Impl_provider.replacement} = candidates in
  (* orig_good is all the implementations passed to the SAT solver (these are the
     ones with a compatible OS, CPU, etc). They are sorted most desirable first. *)
  object (self)
    val mutable notes = []
    val mutable good = orig_good
    val mutable bad = (orig_bad :> (Feed.implementation * rejection_reason) list)

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

    method lit = lit
    method replacement = replacement
    method impl = selected_impl
    method notes = List.rev notes

    method good = good
    method bad = bad

    method original_good = orig_good
    method original_bad = orig_bad
  end

let get_machine_group impl =
  match impl.Feed.machine with
  | None -> None
  | Some "src" -> None
  | Some m -> Some (Arch.get_machine_group m)

let find_component key report =
  try Some (SelMap.find key report)
  with Not_found -> None

(* Did any dependency of [impl] prevent it being selected?
   This can only happen in the case of a cycle (otherwise, we'd select something
   in [impl]'s interface and complain about the dependency instead). *)
let get_dependency_problem report impl =
  let check_dep dep =
    match find_component (dep.Feed.dep_iface, false) report with
    | None -> None      (* Not in the selections => can't be part of a cycle *)
    | Some required_component ->
        match required_component#impl with
        | None -> None  (* Not part of a cycle *)
        | Some dep_impl ->
            let check_restriction r =
              if r#meets_restriction dep_impl then None
              else Some (`DepFailsRestriction (dep, r)) in
            U.first_match check_restriction dep.Feed.dep_restrictions in
  U.first_match check_dep impl.Feed.props.Feed.requires

(** A selected component has [dep] as a dependency. Use this to explain why some implementations
    of the required interface were rejected. *)
let examine_dep requiring_iface requiring_impl report dep =
  let other_iface = dep.Feed.dep_iface in
  let required_component = SelMap.find (other_iface, false) report in

  if dep.Feed.dep_restrictions <> [] then (
    (* Report the restriction *)
    required_component#note (Restricts (requiring_iface, requiring_impl, dep.Feed.dep_restrictions));

    (* Remove implementations incompatible with the other selections *)
    required_component#apply_restrictions dep.Feed.dep_restrictions
  );

  ListLabels.iter dep.Feed.dep_required_commands ~f:(fun command ->
    required_component#note (RequiresCommand (requiring_iface, requiring_impl, command));
    required_component#filter_impls (fun impl ->
      if StringMap.mem command Feed.(impl.props.commands) then None
      else Some (`MissingCommand command)
    )
  )

(* Find all restrictions that are in play and affect this interface *)
let examine_selection report (iface_uri, source) component =
  (* Note any conflicts caused by <replaced-by> elements *)
  let () =
    match component#replacement with
    | Some replacement when SelMap.mem (replacement, source) report ->
        let replacement_component = SelMap.find (replacement, source) report in
        component#note (ReplacedByConflict replacement);
        component#reject_all (`ConflictsInterface replacement);

        replacement_component#note (ReplacesConflict iface_uri);
        replacement_component#reject_all (`ConflictsInterface iface_uri)
    | _ -> () in

  match component#impl with
  | Some our_impl ->
      (* For each dependency of our selected impl, explain why it rejected impls in the dependency's interface. *)
      List.iter (examine_dep iface_uri our_impl report) our_impl.Feed.props.Feed.requires
  | None ->
      (* For each of our remaining unrejected impls, check whether a dependency cycle prevented its selection. *)
      component#filter_impls (get_dependency_problem report)

let reject_if_unselected sat _key component =
  if component#impl = None then (
    component#reject_all (`DiagnosticsFailure (S.explain_reason sat component#lit));
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
      let component = SelMap.find (root_iface, source) report in
      component#filter_impls (fun impl ->
        if StringMap.mem root_command Feed.(impl.props.commands) then None
        else Some (`MissingCommand root_command)
      )
  | Solver.ReqIface _ -> ()

(** Find an implementation which requires a machine group. Use this to
    explain the rejection of all implementations requiring other groups. *)
exception Found of (Feed.implementation * Arch.machine_group)
let check_machine_groups report =
  let check _key compoment =
    match compoment#impl with
    | None -> ()
    | Some impl ->
        match get_machine_group impl with
        | None -> ()
        | Some group -> raise (Found (impl, group)) in

  try SelMap.iter check report
  with Found (example_impl, example_group) ->
    let filter _key component = component#filter_impls (fun impl ->
      match get_machine_group impl with
      | Some group when group <> example_group -> Some (`MachineGroupConflict example_impl)
      | _ -> None
    ) in
    SelMap.iter filter report

let get_failure_report (result:Solver.result) : component SelMap.t =
  let (root_scope, sat, impl_provider, impl_cache, root_req) = result#get_details in

  let report =
    let get_selected map ((iface, source) as key, candidates) =
      match candidates#get_selected with
      | None -> map    (* Not part of the (dummy) solution *)
      | Some (lit, impl) ->
          let impl = if impl.Feed.parsed_version = Versions.dummy then None else Some impl in
          let impl_candidates = impl_provider#get_implementations root_scope.Solver.scope_filter iface ~source in
          let component = new component impl_candidates lit impl in
          SelMap.add key component map in
    List.fold_left get_selected SelMap.empty impl_cache#get_items in

  process_root_req report root_req;
  examine_extra_restrictions report root_scope.Solver.scope_filter.Impl_provider.extra_restrictions;
  check_machine_groups report;
  SelMap.iter (examine_selection report) report;
  SelMap.iter (reject_if_unselected sat) report;

  report

(** Return a message explaining why the solve failed. *)
let get_failure_reason config result : string =
  let reasons = get_failure_report result in

  let buf = Buffer.create 1000 in
  Buffer.add_string buf "Can't find all required implementations:\n";
  SelMap.iter (format_report buf) reasons;
  if config.network_use = Offline then
    Buffer.add_string buf "Note: 0install is in off-line mode\n";
  Buffer.sub buf 0 (Buffer.length buf - 1)

exception Return of string

let return fmt =
  let do_return msg = raise (Return msg) in
  Printf.ksprintf do_return fmt

let get_id sel =
  let feed =
    match ZI.get_attribute_opt Feed.attr_from_feed sel with
    | Some feed -> feed
    | None -> ZI.get_attribute Feed.attr_interface sel in
  let id = ZI.get_attribute Feed.attr_id sel in
  Feed.({feed; id})

(** Is the wanted implementation simply ranked lower than the one we selected?
    @raise Return if so. *)
let maybe_justify_local_preference wanted_id actual_id candidates compare =
  let wanted_impl = ref None in
  let actual_impl = ref None in

  ListLabels.iter candidates ~f:(fun impl ->
    let id = Feed.get_id impl in
    if id = wanted_id then
      wanted_impl := Some impl;
    if id = actual_id then
      actual_impl := Some impl
  );

  match !wanted_impl, !actual_impl with
  | _, None -> failwith "Didn't find actual impl!"
  | None, _ -> failwith "Didn't find wanted impl!"
  | Some wanted_impl, Some actual_impl ->
      (* Was impl ranked below the selected version? *)
      let (result, reason) = compare wanted_impl actual_impl in

      if result > 0 then (
        let reason_msg =
          let open Impl_provider in
          match reason with
          | PreferAvailable -> "is locally available"
          | PreferDistro    -> "native packages are preferred"
          | PreferID        -> "better ID (tie-breaker)"
          | PreferLang      ->  "natural languages we understand are preferred"
          | PreferMachine   -> "better CPU match"
          | PreferNonRoot   -> "packages that don't require admin access to install are preferred"
          | PreferOS        -> "better OS match"
          | PreferStability -> "more stable versions preferred"
          | PreferVersion   -> "newer versions are preferred" in

        (* If they both have the same version number, include the ID in the message too. *)
        let wanted_version = Feed.(get_attr attr_version wanted_impl) in
        let actual_version = Feed.(get_attr attr_version actual_impl) in

        let truncate id =
          if String.length id < 18 then id
          else String.sub id 0 16 ^ "..." in

        let (wanted, actual) =
          if wanted_version = actual_version then
            (spf "%s (%s)" wanted_version @@ truncate wanted_id.Feed.id,
             spf "%s (%s)" actual_version @@ truncate actual_id.Feed.id)
          else
            (wanted_version, actual_version) in

        return "%s is ranked lower than %s: %s" wanted actual reason_msg
      )

(* We are able to select the specimen, but we preferred not to. Explain why.
   [test_sels] is the selections with the constraint.
   [old_sels] are the selections we get with an unconstrained solve. *)
let justify_preference test_sels wanted q_iface wanted_id ~old_sels ~compare candidates =
  let index = Selections.make_selection_map test_sels in

  let actual_selection =
    let is_our_iface sel = ZI.tag sel = Some "selection" && ZI.get_attribute Feed.attr_interface sel = q_iface in
    try Some (List.find is_our_iface old_sels.Qdom.child_nodes)
    with Not_found -> None in

  let () =
    match actual_selection, compare with
    | Some actual_selection, Some compare ->
        let actual_id = get_id actual_selection in

        (* Was impl actually selected anyway? *)
        if get_id actual_selection = wanted_id then
          return "%s was selected as the preferred version." wanted;

        (* Check whether the preference can be explained by the local ranking. *)
        maybe_justify_local_preference wanted_id actual_id candidates compare
    | _ -> () in

  let used_impl = actual_selection <> None in

  (* [wanted] is selectable and ranked higher than the selected version. Selecting it would cause
      a problem elsewhere. Or, its interface just isn't needed. *)
  let changes = ref [] in
  let add fmt =
    let do_add msg = changes := msg :: !changes in
    Printf.ksprintf do_add fmt in

  ZI.iter old_sels ~f:(fun old_sel ->
    let old_iface = ZI.get_attribute Feed.attr_interface old_sel in
    if old_iface <> q_iface || not used_impl then (
      try
        let new_sel = StringMap.find old_iface index in
        let old_version = ZI.get_attribute Feed.attr_version old_sel in
        let new_version = ZI.get_attribute Feed.attr_version new_sel in
        if old_version <> new_version then
          add "%s: %s to %s" old_iface old_version new_version
        else (
          let old_id = ZI.get_attribute Feed.attr_id old_sel in
          let new_id = ZI.get_attribute Feed.attr_id new_sel in
          if old_id <> new_id then
            add "%s: %s to %s" old_iface old_id new_id
        )
      with Not_found ->
        add "%s: no longer used" old_iface
    )
  );

  let changes_text =
    if !changes <> [] then
      "\n\nThe changes would be:\n\n" ^ (String.concat "\n" (List.rev !changes))
    else "" in

  if used_impl then
    return "%s is selectable, but using it would produce a less optimal solution overall.%s" wanted changes_text
  else
    return "If %s were the only option, the best available solution wouldn't use it.%s" wanted changes_text

(** Run a solve with impl_id forced to be selected, and use that to explain why it wasn't (or was)
    selected in the normal case. *)
let justify_decision config feed_provider requirements q_iface q_impl =
  let (scope, root_req) = Solver.get_root_requirements config requirements in

  (* Note: there's a slight mismatch between the diagnostics system (which assumes each interface is used either for
     source or binaries, but not both, and the current implementation of the solver. *)

  let wanted = ref @@ spf "%s %s" q_iface q_impl.Feed.id in

  let candidates = ref [] in

  (* Wrap default_impl_provider so that it only returns our impl for [q_iface]. If impl isn't usable,
     we return early. *)
  let impl_provider =
    let open Impl_provider in
    object
      inherit default_impl_provider config ~watch_iface:q_iface feed_provider as super

      method! get_implementations scope_filter requested_iface ~source:want_source =
        let c = super#get_implementations scope_filter requested_iface ~source:want_source in
        if requested_iface <> q_iface then c
        else (
          candidates := c.impls;
          let is_ours candidate = Feed.get_id candidate = q_impl in
          try
            let our_impl = List.find is_ours c.impls in
            wanted := spf "%s %s" q_iface Feed.(get_attr attr_version our_impl);
            {impls = [our_impl]; replacement = c.replacement; rejects = []}
          with Not_found ->
            try
              let (our_impl, problem) = List.find (fun (cand, _) -> is_ours cand) c.rejects in
              wanted := spf "%s %s" q_iface Feed.(get_attr attr_version our_impl);
              return "%s cannot be used (regardless of other components): %s" !wanted (Impl_provider.describe_problem our_impl problem)
            with Not_found -> return "Implementation to consider (%s) does not exist!" !wanted

        )
    end in

  (* Could a selection involving impl even be valid? *)
  try
    match Solver.do_solve impl_provider scope root_req ~closest_match:false with
    | Some result ->
        let test_sels = result#get_selections in
        let (ready, actual_selections) = Solver.solve_for config feed_provider requirements in
        assert ready;   (* If we can solve we a constraint, we can solve without. *)
        justify_preference test_sels !wanted q_iface q_impl
          ~old_sels:actual_selections#get_selections
          ~compare:impl_provider#get_watched_compare !candidates
    | None ->
        match Solver.do_solve impl_provider scope root_req ~closest_match:true with
        | None -> failwith "No solution, even with closest_match!"
        | Some result ->
            return "There is no possible selection using %s.\n%s" !wanted @@ get_failure_reason config result
  with Return x -> x
