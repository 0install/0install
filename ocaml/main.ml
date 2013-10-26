(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main executable *)

open Support.Common

let main (system:system) : unit =
  match Array.to_list system#argv with
  | [] -> assert false
  | prog :: args ->
      let config = Zeroinstall.Config.get_default_config system prog in
      match String.lowercase @@ Filename.basename prog with
      | "0launch" | "0launch.exe" ->
          begin match args with
          | "_complete" :: args -> Completion.handle_complete config args
          | args -> Cli.handle config ("run" :: args) end
      | "0store" | "0store.exe" -> begin
          match args with
          | "_complete" :: args -> Completion.handle_complete config args
          | args -> Cli.handle config ("store" :: args) end
      | "0install" | "0install.exe" -> begin
          match args with
          | "_complete" :: args -> Completion.handle_complete config args
          | "runenv" :: runenv_args -> Zeroinstall.Exec.runenv system runenv_args
          | raw_args -> Cli.handle config raw_args end
      | "0desktop" | "0desktop.exe" -> begin
          match args with
          | "_complete" :: args -> Completion.handle_complete config args
          | args -> Cli.handle config ("_desktop" :: args) end
      | name -> raise_safe "Unknown command '%s': must be invoked as '0install' or '0launch'" name

let start system =
  Support.Utils.handle_exceptions main system

let start_if_not_windows system =
  if Sys.os_type <> "Win32" then (
    start system;
    exit 0
  )
