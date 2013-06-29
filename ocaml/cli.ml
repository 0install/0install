(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing command-line arguments *)

open General
open Support.Common
open Support.Argparse

let starts_with = Support.Utils.starts_with

let i_ x = x;;

type zi_option =
  | UseGUI of yes_no_maybe
  | Verbose
  | Help
  | DryRun
  | WithStore
  | Wrapper

let options_spec : zi_option opt list = [
  (["-c"; "--console"],    i_ "never use GUI",                     0, UseGUI No);
  ([      "--dry-run"],    i_ "just print what would be executed", 0, DryRun);
  (["-g"; "--gui"],        i_ "show graphical policy editor",      0, UseGUI Yes);
  (["-h"; "--help"],       i_ "show this help message and exit",   0, Help);
  (["-v"; "--verbose"],    i_ "more verbose output",               0, Verbose);
  ([      "--with-store"], i_ "add an implementation cache",       1, WithStore);

  (* Run options *)
  (["-w"; "--wrapper"],    i_ "execute program using a debugger, etc", 1, Wrapper);

];;

type global_settings = {
  config : config;
  mutable gui : yes_no_maybe;
  mutable dry_run : bool;
  mutable verbosity : int;
  mutable extra_options : zi_option option_value list;
  mutable args : string list;
}

let add_store settings store =
  settings.config.stores <- store :: settings.config.stores;
  log_info "Stores search path is now %s" @@ String.concat path_sep settings.config.stores

let increase_verbosity options =
  options.verbosity <- options.verbosity + 1;
  let open Support.Logging in
  Printexc.record_backtrace true;
  if options.verbosity = 1 then (
    threshold := Info;
    (* Print this as soon as possible once logging is on *)
    log_info "OCaml front-end to 0install: entering main"
  ) else (
    threshold := Debug
  )

let parse_args config args =
  let spec : zi_option spec = {
    options_spec;
    no_more_options = function
      | [_; "run"] | [_; "runenv"] -> true
      | _ -> false
  } in

  let (raw_options, args) = try Support.Argparse.parse_args spec args;
  with Unknown_option opt ->
    log_info "Unknown option '%s'" opt;
    raise Fallback_to_Python in

  (* Default values *)
  let options = {
    config;
    gui = Maybe;
    dry_run = false;
    verbosity = 0;
    extra_options = [];
    args;
  } in

  let unhandled = ref [] in

  let handle_global opt = match opt with
    | NoArgOption(UseGUI b) -> options.gui <- b
    | NoArgOption(DryRun) -> raise Fallback_to_Python
    | NoArgOption(Verbose) -> increase_verbosity options
    | OneArgOption(WithStore, store) -> add_store options store
    | _ -> unhandled := opt :: !unhandled
  in

  List.iter handle_global raw_options;

  options.extra_options <- List.rev !unhandled;

  options
;;
