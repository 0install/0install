(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main executable *)

open Zeroinstall.General
open Support
open Support.Common
module U = Support.Utils

(* There's no reason to use SIGPIPE in a language with exceptions. This
   means that the function with the problem will raise an exception, instead
   of terminating the whole program. *)
let () =
  match Sys.os_type with
  | "Unix" | "Cygwin" ->
    let _ : Sys.signal_behavior = Sys.(signal sigpipe Signal_ignore) in ()
  | _ -> ()

let crash_handler system crash_dir entries =
  U.makedirs system crash_dir 0o700;
  let leaf =
    let open Unix in
    let t = gmtime (time ()) in
    Printf.sprintf "%04d-%02d-%02dT%02d_%02dZ"
      (1900 + t.tm_year)
      (t.tm_mon + 1)
      t.tm_mday
      t.tm_hour
      t.tm_min in
  let log_file = crash_dir +/ leaf in
  log_file |> system#with_open_out [Open_append; Open_creat] ~mode:0o600 (fun ch ->
    entries |> List.rev |> List.iter (fun (time, ex, level, msg) ->
      let time = U.format_time (Unix.gmtime time) in
      Printf.fprintf ch "%s: %s: %s\n" time (Support.Logging.string_of_level level) msg;
      ex |> if_some (fun ex -> Printexc.to_string ex |> Printf.fprintf ch "%s\n");
    )
  );
  Printf.fprintf stderr "(wrote crash logs to %s)\n" log_file

let with_config system prog fn =
  let config = Zeroinstall.Config.get_default_config system prog in
  try fn config
  with Common_options.Retry_with_dryrun ->
    let system = new Zeroinstall.Dry_run.dryrun_system system in
    let config = Zeroinstall.Config.get_default_config system prog in
    fn {config with dry_run = true}

let main ~stdout (system:system) : unit =
  begin match system#getenv "ZEROINSTALL_CRASH_LOGS" with
  | Some dir when dir <> "" -> Support.Logging.set_crash_logs_handler (crash_handler system dir)
  | _ -> () end;
  match Array.to_list system#argv with
  | [] -> assert false
  | prog :: args ->
      with_config system prog @@ fun config ->
      match String.lowercase_ascii @@ Filename.basename prog with
      | "0launch" | "0launch.exe" ->
          begin match args with
          | "_complete" :: args -> Completion.handle_complete ~stdout config args
          | args -> Cli.handle ~stdout config ("run" :: args) end
      | "0store" | "0store.exe" -> begin
          match args with
          | "_complete" :: args -> Completion.handle_complete ~stdout config args
          | args -> Cli.handle ~stdout config ("store" :: args) end
      | "0install" | "0install.exe" -> begin
          match args with
          | "_complete" :: args -> Completion.handle_complete ~stdout config args
          | "runenv" :: runenv_args -> Runenv_shared.runenv system runenv_args
          | raw_args -> Cli.handle ~stdout config raw_args end
      | "0desktop" | "0desktop.exe" -> begin
          match args with
          | "_complete" :: args -> Completion.handle_complete ~stdout config args
          | args -> Cli.handle ~stdout config ("_desktop" :: args) end
      | "0alias" | "0alias.exe" ->
          Cli.handle ~stdout config ("_alias" :: args)
      | "0store-secure-add" -> Secureadd.handle config args
      | name -> Safe_exn.failf "Unknown command '%s': must be invoked as '0install' or '0launch'" name

let start system =
  Support.Utils.handle_exceptions (main ~stdout:Format.std_formatter) system

let start_if_not_windows system =
  if Sys.os_type <> "Win32" then (
    start system;
    exit 0
  )
