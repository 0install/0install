(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main executable *)

open Support;;
open Constants;;

let is_option x = String.length x > 0 && x.[0] = '-';;
let is_iface_url x = String.length x > 0 && x.[0] = '-';;

(* We can't handle any of these at the moment, so pass them to the Python. *)
let is_url url =
  let starts = starts_with url in
  starts "http://" || starts "https://" || starts "file:" || starts "alias:"
;;

(** Run "python -m zeroinstall.cmd". If ../zeroinstall exists, put it in PYTHONPATH,
    otherwise use the system version of 0install. *)
let fallback_to_python = function
  | prog :: args ->
      let parent_dir = Filename.dirname (Filename.dirname (abspath prog)) in
      let () = if Sys.file_exists (parent_dir +/ "zeroinstall") then
          Unix.putenv "PYTHONPATH" parent_dir
        else () in
      let python_argv = Array.of_list ("python" :: "-m" :: "zeroinstall.cmd" :: args) in
      flush stdout;
      flush stderr;
      Unix.execvp (python_argv.(0)) python_argv
  | _ -> failwith "No argv[0]"
;;

let main () =
  let argv = (Array.to_list Sys.argv) in
  try
    match argv with
    (* 0install run ... *)
    | (self_path :: "run" :: app_or_sels :: args) when not (is_option app_or_sels) && not (is_url app_or_sels) -> (
      let config = Config.get_default_config self_path in
      let sels = match Apps.lookup_app config app_or_sels with
      | None -> Selections.load_selections app_or_sels
      | Some app_path -> Apps.get_selections config app_path ~may_update:true in
      try Run.execute_selections sels args config
      with Safe_exception _ as ex -> reraise_with_context ex ("... running selections " ^ app_or_sels)
    )
    (* 0install runenv *)
    | (_ :: "runenv" :: runenv_args) -> Run.runenv runenv_args
    (* For all other cases, fall back to the Python version *)
    | _ -> raise Fallback_to_Python
  with Fallback_to_Python -> fallback_to_python argv
;;

let () = handle_exceptions main;;
