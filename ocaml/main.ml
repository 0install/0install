(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main executable *)

open Zeroinstall.General
open Support.Common
open Options

(** Run "python -m zeroinstall.cmd". If ../zeroinstall exists, put it in PYTHONPATH,
    otherwise use the system version of 0install. *)
let fallback_to_python config args =
  let try_with path =
    if config.system#file_exists path then (
      (* Note: on Windows, we need to specify "python" *)
      config.system#exec ~search_path:true ("python" :: path :: "--python-fallback" :: args)
    ) in
  let my_dir = Filename.dirname config.abspath_0install in
  try_with @@ my_dir +/ "0launch";                   (* When installed in /usr/bin *)
  let parent_dir = Filename.dirname my_dir in
  try_with @@ parent_dir +/ "0launch";  (* When running from ocaml directory *)
  try_with @@ Filename.dirname parent_dir +/ "0launch";  (* When running from _build directory *)
  failwith "Can't find 0launch command!"
;;

let main (system:system) : unit =
  let argv = Array.to_list (system#argv ()) in
  let config = Zeroinstall.Config.get_default_config system (List.hd argv) in
  match List.tl argv with
  | "_complete" :: args -> Completion.handle_complete config args
  | "runenv" :: runenv_args -> Zeroinstall.Exec.runenv system runenv_args
  | raw_args ->
      try
        let options =
          try Cli.parse_args config raw_args
          with Safe_exception _ as ex ->
            reraise_with_context ex "... processing command line: %s" (String.concat " " argv)
        in
        try
          match options.args with
          | ("run" :: args) -> Run.handle options args
          | ("select" :: args) -> Select.handle options args
          | ("download" :: args) -> Download.handle options args
          | ("show" :: args) -> Show.handle options args
          | ("man" :: args) -> Man.handle options args
          | _ -> raise Fallback_to_Python
        with Support.Argparse.Usage_error -> Cli.show_usage_error options
      with Fallback_to_Python ->
        log_info "Can't handle this case; switching to Python version...";
        fallback_to_python config (List.tl argv)

let start system =
  Support.Utils.handle_exceptions main system

let start_if_not_windows system =
  if Sys.os_type <> "Win32" then (
    start system;
    exit 0
  )
