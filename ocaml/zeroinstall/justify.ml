(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
open Support.Common
module Qdom = Support.Qdom
module FeedAttr = Constants.FeedAttr

module U = Support.Utils

let spf = Printf.sprintf
let () = ignore on_windows

exception Return of string

let return fmt =
  let do_return msg = raise (Return msg) in
  Printf.ksprintf do_return fmt

(** Is the wanted implementation simply ranked lower than the one we selected?
    @raise Return if so. *)
let maybe_justify_local_preference wanted_id actual_id candidates compare =
  let wanted_impl = ref None in
  let actual_impl = ref None in

  ListLabels.iter candidates ~f:(fun impl ->
    let id = Impl.get_id impl in
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
        let wanted_version = Impl.get_attr_ex FeedAttr.version wanted_impl in
        let actual_version = Impl.get_attr_ex FeedAttr.version actual_impl in

        let truncate id =
          if String.length id < 18 then id
          else String.sub id 0 16 ^ "..." in

        let (wanted, actual) =
          if wanted_version = actual_version then
            (spf "%s (%s)" wanted_version @@ truncate wanted_id.Feed_url.id,
             spf "%s (%s)" actual_version @@ truncate actual_id.Feed_url.id)
          else
            (wanted_version, actual_version) in

        return "%s is ranked lower than %s: %s" wanted actual reason_msg
      )

(* We are able to select the specimen, but we preferred not to. Explain why.
   [test_sels] is the selections with the constraint.
   [old_sels] are the selections we get with an unconstrained solve. *)
let justify_preference test_sels wanted q_iface wanted_id ~old_sels ~compare candidates =
  let actual_selection = Selections.find q_iface old_sels in

  let () =
    match actual_selection, compare with
    | Some actual_selection, Some compare ->
        let actual_id = Selections.get_id actual_selection in

        (* Was impl actually selected anyway? *)
        if actual_id = wanted_id then
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

  old_sels |> Selections.iter (fun old_iface old_sel ->
    if old_iface <> q_iface || not used_impl then (
      match Selections.find old_iface test_sels with
      | Some new_sel ->
          let old_version = ZI.get_attribute FeedAttr.version old_sel in
          let new_version = ZI.get_attribute FeedAttr.version new_sel in
          if old_version <> new_version then
            add "%s: %s to %s" old_iface old_version new_version
          else (
            let old_id = ZI.get_attribute FeedAttr.id old_sel in
            let new_id = ZI.get_attribute FeedAttr.id new_sel in
            if old_id <> new_id then
              add "%s: %s to %s" old_iface old_id new_id
          )
      | None ->
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
  let (scope_filter, root_req) = Solver.get_root_requirements config requirements in

  (* Note: there's a slight mismatch between the diagnostics system (which assumes each interface is used either for
     source or binaries, but not both, and the current implementation of the solver. *)

  let wanted = ref @@ spf "%s %s" q_iface q_impl.Feed_url.id in

  let candidates = ref [] in

  (* Wrap default_impl_provider so that it only returns our impl for [q_iface]. If impl isn't usable,
     we return early. *)
  let impl_provider =
    let open Impl_provider in
    object
      inherit default_impl_provider config feed_provider scope_filter as super
      initializer super#set_watch_iface q_iface

      method! get_implementations requested_iface ~source:want_source =
        let c = super#get_implementations requested_iface ~source:want_source in
        if requested_iface <> q_iface then c
        else (
          candidates := c.impls;
          let is_ours candidate = Impl.get_id candidate = q_impl in
          try
            let our_impl = List.find is_ours c.impls in
            wanted := spf "%s %s" q_iface @@ Impl.get_attr_ex FeedAttr.version our_impl;
            {impls = [our_impl]; replacement = c.replacement; rejects = []}
          with Not_found ->
            try
              let (our_impl, problem) = List.find (fun (cand, _) -> is_ours cand) c.rejects in
              wanted := spf "%s %s" q_iface Impl.(get_attr_ex FeedAttr.version our_impl);
              return "%s cannot be used (regardless of other components): %s" !wanted (Impl_provider.describe_problem our_impl problem)
            with Not_found -> return "Implementation to consider (%s) does not exist!" !wanted

        )
    end in

  (* Could a selection involving impl even be valid? *)
  try
    match Solver.do_solve (impl_provider :> Impl_provider.impl_provider) root_req ~closest_match:false with
    | Some result ->
        let test_sels = Solver.selections result in
        let (ready, actual_selections) = Solver.solve_for config feed_provider requirements in
        assert ready;   (* If we can solve we a constraint, we can solve without. *)
        justify_preference test_sels !wanted q_iface q_impl
          ~old_sels:(Solver.selections actual_selections)
          ~compare:impl_provider#get_watched_compare !candidates
    | None ->
        match Solver.do_solve (impl_provider :> Impl_provider.impl_provider) root_req ~closest_match:true with
        | None -> failwith "No solution, even with closest_match!"
        | Some result ->
            return "There is no possible selection using %s.\n%s" !wanted @@ Solver.get_failure_reason config result
  with Return x -> x
