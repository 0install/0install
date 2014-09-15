(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Getting the dependency tree from a selections document. *)

open Support.Common
open General

module U = Support.Utils
module RoleMap = Solver.Model.RoleMap

(** Convert selections as a dependency tree (as displayed by "0install show",
 * etc). If multiple components share a dependency, only the first one is
 * included. *)
let as_tree sels =
  let seen = Hashtbl.create 10 in (* detect cycles *)

  let rec build_node (uri:string) ~essential =
    if Hashtbl.mem seen uri then None
    else (
      let sel = Selections.find uri sels in

      (* We ignore optional non-selected dependencies; if another component has an
       * essential dependency on it, we'll include it then. *)
      if sel = None && not essential then (
        None
      ) else (
        Hashtbl.add seen uri true;

        let details =
          match sel with
          | Some impl when Element.version_opt impl = None -> `Problem
          | Some impl ->
              let deps = ref [] in

              Element.deps_and_bindings impl |> List.iter (function
                | `command command ->
                    Element.command_children command |> List.iter (function
                      | #Element.dependency as dep -> deps := dep :: !deps
                      | #Element.binding -> ()
                    )
                | #Element.dependency as dep -> deps := dep :: !deps
                | #Element.binding -> ()
              );

              let follow_dep dep =
                let child_iface = Element.interface dep in
                let essential = (Element.importance dep = `essential) in
                build_node child_iface ~essential in

              let children =
                !deps |> U.filter_map (function
                  | `restricts _ -> None
                  | `requires dep -> follow_dep dep
                  | `runner dep -> follow_dep dep
                ) in

              `Selected (impl, children)
          | None ->
              (* Should only happen if we get a malformed selections file. *)
              log_warning "Missing essential dependency on '%s' and no problem reported!" uri;
              `Problem in
        Some (uri, details)
      )
    )
  in

  let root_iface = Selections.root_iface sels in
  match build_node root_iface ~essential:true with
  | None -> assert false
  | Some tree -> tree

(** Like [as_tree] but for a Solver.Model.result.
 * TODO: Should unify these at some point. *)
let result_as_tree result =
  let seen = ref RoleMap.empty in

  let rec build_node role ~essential =
    if RoleMap.mem role !seen then None
    else (
      let sel = Solver.Model.get_selected result role in

      (* We ignore optional non-selected dependencies; if another component has an
       * essential dependency on it, we'll include it then. *)
      if sel = None && not essential then (
        None
      ) else (
        seen := RoleMap.add role true !seen;

        let details =
          match sel with
          | Some impl ->
              let impl_deps, _self_commands = Solver.Model.requires role impl in
              let deps = ref impl_deps in

              Solver.Model.selected_commands result role |> List.iter (fun command_name ->
                let command = Solver.Model.get_command impl command_name
                  |? lazy (raise_safe "BUG: Missing selected command '%s'!" (command_name : Solver.Model.command_name :> string)) in
                let command_deps, _self_commands = Solver.Model.command_requires role command in
                deps := command_deps @ !deps
              );

              let children =
                !deps |> U.filter_map (fun dep ->
                  let {Solver.Model.dep_role; dep_restrictions = _; dep_importance; dep_required_commands = _} = dep in
                  if dep_importance <> `restricts then
                    build_node dep_role ~essential:(dep_importance = `essential)
                  else None
                ) in

              `Selected (impl, children)
          | None ->
              (* Should only happen if we get a malformed selections file. *)
              log_warning "Missing essential dependency on '%s' and no problem reported!" (Solver.Model.Role.to_string role);
              `Problem in
        Some (role, details)
      )
    )
  in

  let root_role =
    match Solver.Model.requirements result with
    | Solver.Model.ReqRole r -> r
    | Solver.Model.ReqCommand (_, r) -> r in
  match build_node root_role ~essential:true with
  | None -> assert false
  | Some tree -> tree

class indenter (printer : string -> unit) =
  object
    val mutable indentation = ""

    method print msg =
      printer (indentation ^ msg ^ "\n")

    method with_indent extra (fn:unit -> unit) =
      let old = indentation in
      indentation <- indentation ^ extra;
      fn ();
      indentation <- old
  end

let print config printer sels =
  let first = ref true in
  let indenter = new indenter printer in
  let printf fmt =
    let do_print msg = indenter#print (msg:string) in
    Printf.ksprintf do_print fmt in

    let rec print_node (uri, details) =
      if !first then
        first := false
      else
        printf "";

      printf "- URI: %s" uri;
      indenter#with_indent "  " (fun () ->
        match details with
        | `Problem ->
            printf "No selected version";
        | `Selected (impl, children) ->
            (* printf "ID: %s" (ZI.get_attribute "id" impl); *)
            printf "Version: %s" (Element.version impl);
            (* print indent + "  Command:", command *)
            let path = match Selections.get_source impl with
              | Selections.PackageSelection -> Printf.sprintf "(%s)" @@ Element.id impl
              | Selections.LocalSelection path -> path
              | Selections.CacheSelection digests ->
                  match Stores.lookup_maybe config.system digests config.stores with
                  | None -> "(not cached)"
                  | Some path -> path in

            printf "Path: %s" path;

            List.iter print_node children;
      )
    in

    print_node @@ as_tree sels
