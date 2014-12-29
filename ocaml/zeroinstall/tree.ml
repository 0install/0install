(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Getting the dependency tree from a selections document. *)

open Support.Common
open General

module U = Support.Utils

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

module Make (Model : Sigs.SELECTIONS) = struct
  (** Convert selections as a dependency tree (as displayed by "0install show",
   * etc). If multiple components share a dependency, only the first one is
   * included. *)
  let as_tree result =
    let seen = ref Model.RoleMap.empty in

    let rec build_node role ~essential =
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

                Model.selected_commands result role |> List.iter (fun command_name ->
                  let command = Model.get_command impl command_name
                    |? lazy (raise_safe "BUG: Missing selected command '%s'!" (command_name : Model.command_name :> string)) in
                  let command_deps, _self_commands = Model.command_requires role command in
                  deps := command_deps @ !deps
                );

                let children =
                  !deps |> U.filter_map (fun dep ->
                    let {Model.dep_role; dep_importance; dep_required_commands = _} = Model.dep_info dep in
                    if dep_importance <> `restricts then
                      build_node dep_role ~essential:(dep_importance = `essential)
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

let print config printer sels =
  let first = ref true in
  let indenter = new indenter printer in
  let printf fmt =
    let do_print msg = indenter#print (msg:string) in
    Printf.ksprintf do_print fmt in

    let rec print_node (role, details) =
      if !first then
        first := false
      else
        printf "";

      printf "- URI: %s" (Selections.Role.to_string role);
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

    print_node @@ SelectionsTree.as_tree sels
