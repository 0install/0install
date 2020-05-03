(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
open Support.Common
open General

module U = Support.Utils

module Make (Model : Sigs.SELECTIONS) = struct
  type node =
    Model.Role.t * [
      | `Problem
      | `Selected of Model.impl * node list
    ]

  (** Convert selections as a dependency tree (as displayed by "0install show",
   * etc). If multiple components share a dependency, only the first one is
   * included. *)
  let as_tree result : node =
    let seen = ref Model.RoleMap.empty in

    let rec build_node role ~essential : node option =
      if Model.RoleMap.mem role !seen then None
      else (
        let sel = Model.get_selected role result in

        (* We ignore optional non-selected dependencies; if another component has an
         * essential dependency on it, we'll include it then. *)
        if sel = None && not essential then (
          None
        ) else (
          seen := Model.RoleMap.add role true !seen;

          let details =
            match sel with
            | Some impl ->
                let impl_deps, _self_commands = Model.requires role impl in
                let deps = ref impl_deps in

                Model.selected_commands impl |> List.iter (fun command_name ->
                  let command = Model.get_command impl command_name
                    |? lazy (Safe_exn.failf "BUG: Missing selected command '%s'!" (command_name : Model.command_name :> string)) in
                  let command_deps, _self_commands = Model.command_requires role command in
                  deps := command_deps @ !deps
                );

                let children =
                  !deps |> List.filter_map (fun dep ->
                    let {Model.dep_role; dep_importance; dep_required_commands = _} = Model.dep_info dep in
                    if dep_importance <> `Restricts then
                      build_node dep_role ~essential:(dep_importance = `Essential)
                    else None
                  ) in

                `Selected (impl, children)
            | None ->
                (* Should only happen if we get a malformed selections file or a failed solve. *)
                (* log_warning "Missing essential dependency on '%s' and no problem reported!" (Model.Role.to_string role); *)
                `Problem in
          Some (role, details)
        )
      )
    in

    let root_req = Model.requirements result in
    match build_node root_req.Model.role ~essential:true with
    | None -> assert false
    | Some tree -> tree
end

module SelectionsTree = Make(Selections)

let pp_path config f impl =
  match Selections.get_source impl with
  | Selections.PackageSelection -> Format.fprintf f "(%s)" @@ Element.id impl
  | Selections.LocalSelection path -> Format.pp_print_string f path
  | Selections.CacheSelection digests ->
    match Stores.lookup_maybe config.system digests config.stores with
    | None -> Format.pp_print_string f "(not cached)"
    | Some path -> Format.pp_print_string f path

let pp_spacer_line f () =
  Format.pp_print_cut f ();
  Format.pp_print_cut f ()

let requires_compilation impl =
  if Element.requires_compilation impl = Some true then " (requires compilation)"
  else ""

let print config f sels =
  let rec print_node f (role, details) =
    Format.fprintf f "- @[<v>URI: %a@,%a@]" Selections.Role.pp role pp_details details
  and pp_details f = function
    | `Problem ->
      Format.fprintf f "No selected version"
    | `Selected (impl, children) ->
      (* Format.fprintf f "@,ID: %s" (ZI.get_attribute "id" impl); *)
      Format.fprintf f "Version: %s%s" (Element.version impl) (requires_compilation impl);
      Format.fprintf f "@,Path: %a" (pp_path config) impl;
      if children <> [] then (
        pp_spacer_line f ();
        Format.pp_print_list ~pp_sep:pp_spacer_line print_node f children
      )
  in
  print_node f @@ SelectionsTree.as_tree sels
