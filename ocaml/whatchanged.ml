(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install whatchanged" command *)

open Options
open Zeroinstall.General
open Support.Common
module Qdom = Support.Qdom
module U = Support.Utils

let show_changes (system:system) old_selections new_selections =
  let changes = ref false in

  let old_index = Zeroinstall.Selections.make_selection_map old_selections in
  let new_index = Zeroinstall.Selections.make_selection_map new_selections in

  let lookup name index =
    try Some (StringMap.find name index)
    with Not_found -> None in

  let v sel = ZI.get_attribute "version" sel in

  let print fmt = Support.Utils.print system fmt in

  old_selections |> ZI.iter ~name:"selection" (fun old_sel ->
    let iface = ZI.get_attribute "interface" old_sel in
    match lookup iface new_index with
    | None ->
        print "No longer used: %s" iface;
        changes := true
    | Some new_sel ->
        if (v old_sel) <> (v new_sel) then (
          print "%s: %s -> %s" iface (v old_sel) (v new_sel);
          changes := true
        )
  );

  new_selections |> ZI.iter ~name:"selection" (fun new_sel ->
    let iface = ZI.get_attribute "interface" new_sel in
    if not (StringMap.mem iface old_index) then (
      print "%s: new -> %s" iface (v new_sel);
      changes := true
    )
  );
  
  !changes

let show_app_changes options ~full app =
  let module A = Zeroinstall.Apps in
  let config = options.config in
  let system = config.system in
  let print fmt = U.print system fmt in

  match A.get_history config app with
  | [] -> raise_safe "Invalid application: no selections found! Try '0install destroy %s'" (Filename.basename app)
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
            let changes = show_changes system old_sels current_sels in
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
      | None -> raise_safe "No such application '%s'" name
      | Some app -> show_app_changes options ~full:!full app
  )
  | _ -> raise (Support.Argparse.Usage_error 1)
