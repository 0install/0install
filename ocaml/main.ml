(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main executable *)

open Support.Common

let main (system:system) : unit =
  let argv = Array.to_list (system#argv ()) in
  let config = Zeroinstall.Config.get_default_config system (List.hd argv) in
  match List.tl argv with
  | "_complete" :: args -> Completion.handle_complete config args
  | "runenv" :: runenv_args -> Zeroinstall.Exec.runenv system runenv_args
  | raw_args -> Cli.handle config raw_args

let start system =
  Support.Utils.handle_exceptions main system

let start_if_not_windows system =
  if Sys.os_type <> "Win32" then (
    start system;
    exit 0
  )
