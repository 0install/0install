(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install whatchanged" command *)

open Options
open Zeroinstall.General
open Support
open Support.Common
module U = Support.Utils
module Selections = Zeroinstall.Selections

let show_changes f old_selections new_selections =
  let changes = ref false in
  let v sel = Zeroinstall.Element.version sel in
  let print fmt = Format.fprintf f (fmt ^^ "@.") in

  old_selections
  |> if_some (Selections.iter (fun role old_sel ->
    match Selections.get_selected role new_selections with
    | None ->
        print "No longer used: %a" Selections.Role.pp role;
        changes := true
    | Some new_sel ->
        if (v old_sel) <> (v new_sel) then (
          print "%a: %s -> %s" Selections.Role.pp role (v old_sel) (v new_sel);
          changes := true
        )
  ));

  new_selections |> Selections.iter (fun role new_sel ->
    let old_sel = old_selections |> pipe_some (Selections.get_selected role) in
    if old_sel = None then (
      print "%a: new -> %s" Selections.Role.pp role (v new_sel);
      changes := true
    )
  );
  
  !changes

let show_app_changes options ~full app =
  let module A = Zeroinstall.Apps in
  let config = options.config in
  let system = config.system in
  let print fmt = Format.fprintf options.stdout (fmt ^^ "@.") in

  match A.get_history config app with
  | [] -> Safe_exn.failf "Invalid application: no selections found! Try '0install destroy %s'" (Filename.basename app)
  | current :: history ->
      let times = A.get_times system app in
      if times.A.last_check_time <> 0.0 then
        print "Last checked    : %s" (U.format_time_pretty @@ Unix.gmtime times.A.last_check_time);
      let () = 
        match times.A.last_check_attempt with
        | Some attempt ->
            print "Last attempt    : %s" (U.format_time_pretty @@ Unix.gmtime attempt);
        | None -> () in

      print "Last update     : %s" current;
      let current_sels = A.get_selections_no_updates system app in

      match history with
      | [] ->
          print "No previous history to compare against.";
          print "Use \"0install show %s\" to see the current selections." (Filename.basename app);
      | previous :: _ ->
          print "Previous update : %s" previous;

          let get_selections_path date = app +/ Printf.sprintf "selections-%s.xml" date in

          print "";

          if full then (
            let argv = ["diff"; "-u"; "--"; get_selections_path previous; get_selections_path current] in
            let child = system#create_process argv Unix.stdin Unix.stdout Unix.stderr in
            flush stdout;
            match snd @@ system#waitpid_non_intr child with
            | Unix.WEXITED (0|1) -> ()    (* OK, 1 just means changes found *)
            | x -> Support.System.check_exit_status x
          ) else (
            let old_sels = Zeroinstall.Selections.load_selections system @@ get_selections_path previous in
            let changes = show_changes options.stdout (Some old_sels) current_sels in
            if not changes then
              print "No changes to versions (use --full to see all changes)."
          );

          print "";
          print "To run using the previous selections, use:";
          print "0install run %s" (get_selections_path previous)

let handle options flags args =
  let full = ref false in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
    | `ShowFullDiff -> full := true
  );
  match args with
  | [name] -> (
      match Zeroinstall.Apps.lookup_app options.config name with
      | None -> Safe_exn.failf "No such application '%s'" name
      | Some app -> show_app_changes options ~full:!full app
  )
  | _ -> raise (Support.Argparse.Usage_error 1)
