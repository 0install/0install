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

let show_human config sels =
  Zeroinstall.Tree.print config config.system#print_string sels

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
          Apps.get_selections_no_updates system app_path
      | None ->
          Selections.load_selections config.system arg in

      match (!s_root, !s_xml) with
      | (true, false) -> system#print_string (ZI.get_attribute "interface" sels ^ "\n")
      | (false, true) -> show_xml sels
      | (false, false) -> show_human config sels
      | (true, true) -> raise_safe "Can't use --xml with --root"
  )
  | _ -> raise (Support.Argparse.Usage_error 1)
