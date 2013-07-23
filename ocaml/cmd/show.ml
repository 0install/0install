(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install show" command *)

open General
open Support.Common
open Options
module Qdom = Support.Qdom

let make_selection_map sels =
  let add_selection m sel =
    StringMap.add (ZI.get_attribute "interface" sel) sel m
  in ZI.fold_left ~f:add_selection StringMap.empty sels "selection"

let show_human config sels =
  let open Format in
  try
    let seen = Hashtbl.create 10 in (* detect cycles *)
    let index = make_selection_map sels in

    open_box 0;

    let rec print_node uri commands =
      if not (Hashtbl.mem seen uri) then (
        Hashtbl.add seen uri true;

        print_cut();
        print_cut();
        open_vbox 2;

        printf "- URI: %s@," uri;

        let sel =
          try Some (StringMap.find uri index)
          with Not_found -> None in

        let () =
          match sel with
          | None ->
              printf "No selected version";
          | Some impl ->
              printf "Version: %s@," (ZI.get_attribute "version" impl);
              (* print indent + "  Command:", command *)
              let path = match Selections.make_selection impl with
                | Selections.PackageSelection -> sprintf "(%s)" @@ ZI.get_attribute "id" impl
                | Selections.LocalSelection path -> path
                | Selections.CacheSelection digests ->
                    match Stores.lookup_maybe digests config.stores with
                    | None -> "(not cached)"
                    | Some path -> path in

              open_vbox 0;
              printf "Path: %s" path;

              let deps = ref @@ Selections.get_dependencies ~restricts:false impl in

              ListLabels.iter commands ~f:(fun c ->
                let command = Command.get_command c impl in
                deps := !deps @ Selections.get_dependencies ~restricts:false command
              );

              ListLabels.iter !deps ~f:(fun child ->
                let child_iface = ZI.get_attribute "interface" child in
                print_node child_iface (Selections.get_required_commands child)
              );
              close_box() in
        close_box()
      )
    in

    let root_iface = ZI.get_attribute "interface" sels in
    let () = match ZI.get_attribute_opt "command" sels with
      | None | Some "" -> print_node root_iface []
      | Some command -> print_node root_iface [command] in

    close_box();
    print_newline()
  with ex ->
    print_newline();
    raise ex

let show_xml sels =
  let out = Xmlm.make_output @@ `Channel stdout in
  Qdom.output out sels;
  output_string stdout "\n"

let show_restrictions (system:system) r =
  let open Requirements in
  let print = Support.Utils.print in
  if r.extra_restrictions <> StringMap.empty then (
    print system "User-provided restrictions in force:";
    let show iface expr =
      print system "  %s: %s" iface expr in
    StringMap.iter show r.extra_restrictions;
    system#print_string "\n"
  )

let handle options args =
  let config = options.config in
  let system = config.system in
  match args with
  | [arg] -> (
      let s_root = ref false in
      let s_xml = ref false in

      Support.Argparse.iter_options options.extra_options (function
        | ShowRoot -> s_root := true
        | ShowXML -> s_xml := true
        | _ -> raise_safe "Unknown option"
      );

      let sels = match Apps.lookup_app config arg with
      | Some app_path ->
          let r = Apps.get_requirements system app_path in
          if not !s_xml && not !s_root then
            show_restrictions system r;
          Apps.get_selections config app_path ~may_update:false;
      | None ->
          Selections.load_selections config.system arg in

      match (!s_root, !s_xml) with
      | (true, false) -> system#print_string (ZI.get_attribute "interface" sels ^ "\n")
      | (false, true) -> show_xml sels
      | (false, false) -> show_human config sels
      | (true, true) -> raise_safe "Can't use --xml with --root"
  )
  | _ -> raise Support.Argparse.Usage_error
