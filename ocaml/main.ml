(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main executable *)

open General
open Support.Common

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

let main argv =
  let system = new Support.System.real_system in
  let config = Config.get_default_config system (List.hd argv) in
  try
    let settings = Cli.parse_args config (List.tl argv) in
    log_info "OCaml front-end to 0install: entering main";
    match settings.Cli.args with
    (* 0install run ... *)
    | ("run" :: app_or_sels :: args) when not (is_option app_or_sels) && not (is_url app_or_sels) -> (
      let sels = match Apps.lookup_app config app_or_sels with
      | None -> Selections.load_selections config.system app_or_sels
      | Some app_path -> Apps.get_selections config app_path ~may_update:true in
      try Run.execute_selections sels args config
      with Safe_exception _ as ex -> reraise_with_context ex ("... running selections " ^ app_or_sels)
    )
    (* 0install runenv *)
    | ("runenv" :: runenv_args) -> Run.runenv runenv_args
    (* For all other cases, fall back to the Python version *)
    | _ -> raise Fallback_to_Python
  with Fallback_to_Python ->
    log_info "Can't handle this case; switching to Python version...";
    fallback_to_python config (List.tl argv)
;;

let () = Support.Utils.handle_exceptions main (Array.to_list Sys.argv)
