(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install show" command *)

open Zeroinstall.General
open Support.Common
open Options
module Qdom = Support.Qdom
module Selections = Zeroinstall.Selections
module Apps = Zeroinstall.Apps

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

let show_human config sels =
  let first = ref true in
  let indenter = new indenter config.system#print_string in
  let printf fmt =
    let do_print msg = indenter#print (msg:string) in
    Printf.ksprintf do_print fmt in
  try
    let seen = Hashtbl.create 10 in (* detect cycles *)
    let index = Selections.make_selection_map sels in

    let rec print_node (uri:string) commands =
      if not (Hashtbl.mem seen uri) then (
        Hashtbl.add seen uri true;

        if !first then
          first := false
        else
          printf "";

        printf "- URI: %s" uri;
        indenter#with_indent "  " (fun () ->
          let sel =
            try Some (StringMap.find uri index)
            with Not_found -> None in

          match sel with
          | None ->
              printf "No selected version";
          | Some impl ->
              (* printf "ID: %s" (ZI.get_attribute "id" impl); *)
              printf "Version: %s" (ZI.get_attribute "version" impl);
              (* print indent + "  Command:", command *)
              let path = match Selections.make_selection impl with
                | Selections.PackageSelection -> Printf.sprintf "(%s)" @@ ZI.get_attribute "id" impl
                | Selections.LocalSelection path -> path
                | Selections.CacheSelection digests ->
                    match Zeroinstall.Stores.lookup_maybe config.system digests config.stores with
                    | None -> "(not cached)"
                    | Some path -> path in

              printf "Path: %s" path;

              let deps = ref @@ Selections.get_dependencies ~restricts:false impl in

              ListLabels.iter commands ~f:(fun c ->
                let command = Zeroinstall.Command.get_command c impl in
                deps := !deps @ Selections.get_dependencies ~restricts:false command
              );

              ListLabels.iter !deps ~f:(fun child ->
                let child_iface = ZI.get_attribute "interface" child in
                print_node child_iface (Selections.get_required_commands child)
              );
        )
      )
    in

    let root_iface = ZI.get_attribute "interface" sels in
    match ZI.get_attribute_opt "command" sels with
      | None | Some "" -> print_node root_iface []
      | Some command -> print_node root_iface [command]
  with ex ->
    raise ex

let show_xml sels =
  let out = Xmlm.make_output @@ `Channel stdout in
  Qdom.reindent sels;
  Qdom.output out sels;
  output_string stdout "\n"

let show_restrictions (system:system) r =
  let open Zeroinstall.Requirements in
  let print = Support.Utils.print in
  if r.extra_restrictions <> StringMap.empty then (
    print system "User-provided restrictions in force:";
    let show iface expr =
      print system "  %s: %s" iface expr in
    StringMap.iter show r.extra_restrictions;
    system#print_string "\n"
  )

let handle options flags args =
  let s_root = ref false in
  let s_xml = ref false in

  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
    | `ShowRoot -> s_root := true
    | `ShowXML -> s_xml := true
  );

  let config = options.config in
  let system = config.system in
  match args with
  | [arg] -> (
      let sels = match Apps.lookup_app config arg with
      | Some app_path ->
          let r = Apps.get_requirements system app_path in
          if not !s_xml && not !s_root then
            show_restrictions system r;
          Apps.get_selections_no_updates config app_path
      | None ->
          Selections.load_selections config.system arg in

      match (!s_root, !s_xml) with
      | (true, false) -> system#print_string (ZI.get_attribute "interface" sels ^ "\n")
      | (false, true) -> show_xml sels
      | (false, false) -> show_human config sels
      | (true, true) -> raise_safe "Can't use --xml with --root"
  )
  | _ -> raise (Support.Argparse.Usage_error 1)
