(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Getting the dependency tree from a selections document. *)

open Support.Common
open General

module U = Support.Utils

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

              Element.selection_children impl |> List.iter (function
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
