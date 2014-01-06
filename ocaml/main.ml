(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main executable *)

open Support.Common
module U = Support.Utils

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

let main (system:system) : unit =
IFDEF HAVE_GTK THEN
  (* Install Lwt<->Glib integration in case we need the GUI.
   * LWT <= 2.4.4 is buggy (https://github.com/ocsigen/lwt/issues/25) so we have
   * to be careful... *)
  if system#platform.Platform.os = "Linux" then (
     (* On Linux:
      * - lwt_into_glib mode hangs for LWT <= 2.4.4
      * - glib_into_lwt works on all versions, so use that *)
    Lwt_glib.install ~mode:`glib_into_lwt ()
  ) else (
    (* Otherwise, glib_into_lwt never works, so use lwt_into_glib (and require LWT > 2.4.4). *)
    Lwt_glib.install ~mode:`lwt_into_glib ()
  )
ENDIF;

  begin match system#getenv "ZEROINSTALL_CRASH_LOGS" with
  | Some dir when dir <> "" -> Support.Logging.set_crash_logs_handler (crash_handler system dir)
  | _ -> () end;

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
          | "runenv" :: runenv_args -> Runenv_shared.runenv system runenv_args
          | raw_args -> Cli.handle config raw_args end
      | "0desktop" | "0desktop.exe" -> begin
          match args with
          | "_complete" :: args -> Completion.handle_complete config args
          | args -> Cli.handle config ("_desktop" :: args) end
      | "0alias" | "0alias.exe" ->
          Cli.handle config ("_alias" :: args)
      | "0store-secure-add" -> Secureadd.handle config args
      | name -> raise_safe "Unknown command '%s': must be invoked as '0install' or '0launch'" name

let start system =
  Support.Utils.handle_exceptions main system

let start_if_not_windows system =
  if Sys.os_type <> "Win32" then (
    start system;
    exit 0
  )
