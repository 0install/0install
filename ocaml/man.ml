(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install man" command *)

open Options
open Support.Common
open Zeroinstall.General
module U = Support.Utils
module Qdom = Support.Qdom
module Env = Zeroinstall.Env

(** Exec the man command. Never returns. *)
let exec_man config ?env args =
  let args = "man" :: args in
  if config.dry_run then (
    Zeroinstall.Dry_run.log "%s" @@ Support.Logging.format_argv_for_logging args;
    exit 0
  ) else config.system#exec ?env ~search_path:true args

(** Exec the man command to show the man-page for this interface. Never returns. *)
let find_and_exec_man config ?main ?fallback_name sels =
  let interface_uri = ZI.get_attribute "interface" sels in
  let is_main_impl elem = (ZI.tag elem = Some "selection" && ZI.get_attribute "interface" elem = interface_uri) in
  let selected_impl = List.find is_main_impl sels.Qdom.child_nodes in
  let system = config.system in

  let main =
    match main with
    | Some main -> main
    | None ->
        let command_name = ZI.get_attribute "command" sels in
        let selected_command = Zeroinstall.Command.get_command command_name selected_impl in
        match ZI.get_attribute_opt "path" selected_command with
        | None -> Qdom.raise_elem "No main program for interface '%s'" interface_uri selected_command
        | Some path -> path in

  let prog_name = Filename.basename main in

  match Zeroinstall.Selections.get_path system config.stores selected_impl with
  | None ->
      (* Package implementation *)
      log_debug "Searching for man-page native command %s (from %s)" prog_name (default "(no fallback)" fallback_name);
      exec_man config [prog_name];
  | Some impl_path ->
      log_debug "Searching for man-page for %s or %s in %s" prog_name (default "(no fallback)" fallback_name) impl_path;

      (* TODO: the feed should say where the man-pages are, but for now we'll accept
         a directory called man in some common locations... *)
      ListLabels.iter ["man"; "share/man"; "usr/man"; "usr/share/man"] ~f:(fun mandir ->
        let manpath = impl_path +/ mandir in
        if U.is_dir system manpath then (
          (* Note: unlike "man -M", this also copes with LANG settings... *)
          let env = Env.copy_current_env () in
          Zeroinstall.Env.putenv "MANPATH" manpath env;
          exec_man config ~env:(Env.to_array env) [prog_name];
        )
      );

      (* No man directory given or found, so try searching for man files *)

      let manpages = ref [] in
      let rec walk path =
        match system#readdir path with
        | Problem ex -> log_warning ~ex "Can't read directory '%s'" path
        | Success items ->
            ArrayLabels.iter items ~f:(fun item ->
              let full_path = path +/ item in
              match system#lstat full_path with
              | None -> ()
              | Some info when info.Unix.st_kind = Unix.S_DIR ->
                  if not (U.starts_with item ".") then
                    walk full_path
              | Some _file ->
                  let manpage_file =
                    if Filename.check_suffix item ".gz" then Filename.chop_suffix item ".gz" else item in
                  if Filename.check_suffix manpage_file ".1" ||
                     Filename.check_suffix manpage_file ".6" ||
                     Filename.check_suffix manpage_file ".8" then (
                    let manpage_prog = Filename.chop_extension manpage_file in
                    if manpage_prog = prog_name || Some manpage_prog = fallback_name then
                      exec_man config [full_path]
                    else
                      manpages := full_path :: !manpages
                  )
            ) in
      walk impl_path;

      system#print_string @@ Printf.sprintf "No matching manpage was found for '%s' (%s)\n" (default "(no fallback)" fallback_name) interface_uri;
      if !manpages <> [] then (
        system#print_string "These non-matching man-pages were found, however:\n";
        List.iter (fun n -> system#print_string @@ n ^ "\n") !manpages;
      );
      exit 1

let handle options flags args =
  let config = options.config in
  let system = config.system in

  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );

  match args with
  | [arg] -> (
      let open Zeroinstall.Launcher in
      match U.find_in_path system arg with
      | None -> exec_man config args                  (* Not an executable in PATH *)
      | Some path ->
          let (sels, main) =
            match parse_script system path with
            | None -> exec_man config args              (* Not a 0install executable *)
            | Some (AliasScript {uri; command; main}) -> (
                let command = Some (default "run" command) in
                let reqs = {(Zeroinstall.Requirements.default_requirements uri) with Zeroinstall.Requirements.command} in
                (* Ensure cached *)
                match Generic_select.get_selections options ~refresh:false reqs Zeroinstall.Helpers.Download_only with
                | Some sels -> (sels, main)
                | None -> exit 1
            )
            | Some (AppLauncher app_name) ->
                match Zeroinstall.Apps.lookup_app options.config app_name with
                | None -> raise_safe "App '%s' not installed!" app_name
                | Some app ->
                    (Zeroinstall.Apps.get_selections_no_updates options.config app, None) in
          find_and_exec_man options.config ?main ~fallback_name:arg sels
  )
  | _ -> exec_man config args
