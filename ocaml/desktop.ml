(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Options
open Support.Common
open Zeroinstall.General

module FeedAttr = Zeroinstall.Constants.FeedAttr
module U = Support.Utils

(** Use [xdg-open] to show the help files for this implementation. *)
let show_help config sel =
  let system = config.system in
  let help_dir = ZI.get_attribute_opt FeedAttr.doc_dir sel in
  let id = ZI.get_attribute FeedAttr.id sel in

  let path =
    if U.starts_with id "package:" then (
      match help_dir with
      | None -> raise_safe "No doc-dir specified for package implementation"
      | Some help_dir ->
          if Filename.is_relative help_dir then
            raise_safe "Package doc-dir must be absolute! (got '%s')" help_dir
          else
            help_dir
    ) else (
      let path = Zeroinstall.Selections.get_path system config.stores sel |? lazy (raise_safe "BUG: not cached!") in
      match help_dir with
      | Some help_dir -> path +/ help_dir
      | None ->
          match Zeroinstall.Command.get_command "run" sel with
          | None -> path
          | Some run ->
              match ZI.get_attribute_opt "path" run with
              | None -> path
              | Some main ->
                  (* Hack for ROX applications. They should be updated to set doc-dir. *)
                  let help_dir = path +/ (Filename.dirname main) +/ "Help" in
                  if U.is_dir system help_dir then help_dir
                  else path
    ) in

  (* xdg-open has no "safe" mode, so check we're not "opening" an application. *)
  if system#file_exists (path +/ "AppRun") then
    raise_safe "Documentation directory '%s' is an AppDir; refusing to open" path
  else
    system#exec ~search_path:true ["xdg-open"; path]

let handle_help options flags args =
  let select_opts = ref [] in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
    | #select_option | `Refresh as o -> select_opts := o :: !select_opts
  );
  match args with
  | [arg] ->
      let sels = Generic_select.handle options !select_opts arg `Download_only in
      let index = Zeroinstall.Selections.make_selection_map sels in
      let root = ZI.get_attribute "interface" sels in
      let sel = StringMap.find root index in
      show_help options.config sel
  | _ -> raise (Support.Argparse.Usage_error 1)
