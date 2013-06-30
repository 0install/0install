(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main executable *)

open General
open Support.Common
open Options

let is_option x = String.length x > 0 && x.[0] = '-';;
let is_iface_url x = String.length x > 0 && x.[0] = '-';;

(* We can't handle any of these at the moment, so pass them to the Python. *)
let is_url url =
  let starts = Support.Utils.starts_with url in
  starts "http://" || starts "https://" || starts "file:" || starts "alias:"
;;

(** Run "python -m zeroinstall.cmd". If ../zeroinstall exists, put it in PYTHONPATH,
    otherwise use the system version of 0install. *)
let fallback_to_python config args =
  let parent_dir = Filename.dirname (Filename.dirname config.abspath_0install) in
  let () = if Sys.file_exists (parent_dir +/ "zeroinstall") then
      Unix.putenv "PYTHONPATH" parent_dir in
  config.system#exec ~search_path:true ("python" :: "-m" :: "zeroinstall.cmd" :: args)
;;

let handle_run config options args : unit =
  let wrapper = ref None in
  Support.Argparse.iter_options options.extra_options (function
    | Wrapper w -> wrapper := Some w
    | _ -> raise Fallback_to_Python
  );
  match args with
  | app_or_sels :: run_args when not (is_option app_or_sels) && not (is_url app_or_sels) -> (
      let sels = match Apps.lookup_app config app_or_sels with
      | None -> Selections.load_selections config.system app_or_sels
      | Some app_path -> Apps.get_selections config app_path ~may_update:true in
      try Run.execute_selections config sels run_args ?wrapper:!wrapper
      with Safe_exception _ as ex -> reraise_with_context ex "... running selections %s" app_or_sels
    )
  | _ -> raise Fallback_to_Python
;;

let main argv : unit =
  let system = new Support.System.real_system in
  let config = Config.get_default_config system (List.hd argv) in
  try
    match List.tl argv with
    | "_complete" :: args -> Completion.handle_complete config args
    | "runenv" :: runenv_args -> Run.runenv runenv_args
    | raw_args ->
        let options =
          try Cli.parse_args config raw_args
          with Safe_exception _ as ex ->
            reraise_with_context ex "... processing command line: %s" (String.concat " " argv)
        in
        match options.args with
        | ("run" :: run_args) -> handle_run config options run_args
        | _ -> raise Fallback_to_Python
  with Fallback_to_Python ->
    log_info "Can't handle this case; switching to Python version...";
    fallback_to_python config (List.tl argv)
;;

let () = Support.Utils.handle_exceptions main (Array.to_list Sys.argv)
