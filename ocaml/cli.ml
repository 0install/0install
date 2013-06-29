(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing command-line arguments *)

open General
open Support.Common
open Support.Argparse

let starts_with = Support.Utils.starts_with

let i_ x = x;;

type global_settings = {
  config : config;
  mutable gui : yes_no_maybe;
  mutable dry_run : bool;
  mutable verbosity : int;
  mutable args : string list;

  mutable wrapper : string option;
}

let increase_verbosity settings =
  settings.verbosity <- settings.verbosity + 1;
  let open Support.Logging in
  Printexc.record_backtrace true;
  if settings.verbosity = 1 then
    threshold := Info
  else
    threshold := Debug

let append_store settings store =
  settings.config.stores <- store :: settings.config.stores;
  log_info "Stores search path is now %s" @@ String.concat path_sep settings.config.stores

let global_options = [
  (["-c"; "--console"],    i_ "never use GUI",                     NoArg (fun s -> s.gui <- No));
  ([      "--dry-run"],    i_ "just print what would be executed", NoArg (fun s -> s.dry_run <- true; raise Fallback_to_Python));
  (["-g"; "--gui"],        i_ "show graphical policy editor",      NoArg (fun s -> s.gui <- Yes; raise Fallback_to_Python));
  (["-h"; "--help"],       i_ "show this help message and exit",   NoArg (fun _ -> raise Fallback_to_Python));
  (["-v"; "--verbose"],    i_ "more verbose output",               NoArg increase_verbosity);
  ([      "--with-store"], i_ "add an implementation cache",       OneArg append_store);

  (* Run options *)
  (["-w"; "--wrapper"],    i_ "execute program using a debugger, etc", OneArg (fun s arg -> s.wrapper <- Some arg));

];;

let parse_args config args =
  (* Default values *)
  let settings = {
    config;
    gui = Maybe;
    dry_run = false;
    verbosity = 0;
    args = [];
    wrapper = None;
  } in

  let handle_arg allow_options arg =
    if (List.length settings.args) = 1 then (
      match List.hd settings.args with
      | "run" | "runenv" -> allow_options := false;
      | _ -> ()
    );
    settings.args <- arg :: settings.args in

  let spec : global_settings Support.Argparse.spec = {
    options = global_options;
    arg_handler = handle_arg;
  } in

  let () = try Support.Argparse.parse_args spec settings args;
  with Unknown_option opt ->
    log_info "Unknown option '%s'" opt;
    raise Fallback_to_Python in

  settings.args <- List.rev settings.args;
  settings
;;

let dump settings =
  if !Support.Logging.threshold <= Support.Logging.Info then (
    log_info "use gui = %s" @@ string_of_maybe settings.gui;
    log_info "dry run = %b" settings.dry_run;
    log_info "verbosity = %d" settings.verbosity;
    log_info "args = %s" @@ String.concat " " settings.args;
  )
