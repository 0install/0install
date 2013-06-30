(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing command-line arguments *)

open General
open Support.Common
open Support.Argparse

let starts_with = Support.Utils.starts_with

let i_ x = x;;

type version = string

type zi_option =
  | UseGUI of yes_no_maybe
  | Verbose
  | Help
  | DryRun
  | WithStore of string
  | Wrapper of string
  | ShowVersion
  | RequireVersion of version

type zi_arg_type =
  | Dir
  | Command
  | VersionRange

(* This is tricky, because --version does two things:
   [0install --version] shows the version of 0install.
   [0install --version=1 run foo] runs version 1 of "foo". *)
let parse_version_option stream _empty =
  match Stream.peek stream with
  | None -> ShowVersion
  | Some next when starts_with next "-" -> ShowVersion
  | Some next -> Stream.junk stream; RequireVersion next

let spec : (zi_option, zi_arg_type) argparse_spec = {
  options_spec = [
    (* Run options *)
    (["-w"; "--wrapper"],    i_ "execute program using a debugger, etc", [Command], (one_arg @@ fun cmd -> Wrapper cmd));

    (* Select options *)
    ([      "--version"],    i_ "specify version constraint (e.g. '3' or '3..')", [VersionRange], parse_version_option);

    (* Common options (note: common --version must come after the section one) *)
    (["-c"; "--console"],    i_ "never use GUI",                     [], no_arg @@ UseGUI No);
    ([      "--dry-run"],    i_ "just print what would be executed", [], no_arg @@ DryRun);
    (["-g"; "--gui"],        i_ "show graphical policy editor",      [], no_arg @@ UseGUI Yes);
    (["-h"; "--help"],       i_ "show this help message and exit",   [], no_arg @@ Help);
    (["-v"; "--verbose"],    i_ "more verbose output",               [], no_arg @@ Verbose);
    (["-V"; "--version"],    i_ "display version information",       [], parse_version_option);
    ([      "--with-store"], i_ "add an implementation cache",       [Dir], (one_arg @@ fun path -> WithStore path));
  ];
  no_more_options = function
    | [_; "run"] | [_; "runenv"] -> true
    | _ -> false;
}

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

  options.extra_options <- filter_options raw_options (function
    | UseGUI b -> options.gui <- b; true
    | DryRun -> raise Fallback_to_Python
    | Verbose -> increase_verbosity options; true
    | WithStore store -> add_store options store; true
    | ShowVersion -> raise Fallback_to_Python
    | _ -> false
  );

  options
;;
