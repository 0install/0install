(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install show" command *)

open Zeroinstall.General
open Support
open Options
module Qdom = Support.Qdom
module Selections = Zeroinstall.Selections
module Apps = Zeroinstall.Apps

let show_human config f sels =
  Format.fprintf f "%a@." (Zeroinstall.Tree.print config) sels

let show_xml sels =
  let out = Xmlm.make_output @@ `Channel stdout in
  Qdom.reindent sels |> Qdom.output out;
  output_string stdout "\n"

let pp_restrictions f =
  XString.Map.iter @@ fun iface expr ->
  Format.fprintf f "@,%s: %s" iface expr

let show_restrictions f r =
  let open Zeroinstall.Requirements in
  if r.extra_restrictions <> XString.Map.empty then (
    Format.fprintf f
      "@[<v2>User-provided restrictions in force:%a@]@.@."
      pp_restrictions r.extra_restrictions
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
            show_restrictions options.stdout r;
          Apps.get_selections_no_updates system app_path
      | None ->
          Selections.load_selections config.system arg in

      match (!s_root, !s_xml) with
      | (true, false) -> Format.fprintf options.stdout "%s@." Selections.((root_role sels).iface)
      | (false, true) -> show_xml (Selections.as_xml sels)
      | (false, false) -> show_human config options.stdout sels
      | (true, true) -> Safe_exn.failf "Can't use --xml with --root"
  )
  | _ -> raise (Support.Argparse.Usage_error 1)
