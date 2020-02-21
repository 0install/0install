(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Support
open Support.Common
open Support.Argparse

type 'a handler = Options.global_settings -> ([< Options.zi_option ] as 'a) parsed_options -> string list -> unit

type command =
  CommandObj : (string option * 'a handler * ('a, Options.zi_arg_type) opt_spec list ) -> command

let handle (CommandObj (help, handler, valid_options)) options raw_options command_path args =
  let flags = parse_options valid_options raw_options in
  try handler options flags args
  with Usage_error status ->
    let command = String.concat " " command_path in
    Common_options.show_help options.Options.config.system
      valid_options (command ^ " [OPTIONS] " ^ (help |> default ""))
      options.Options.stdout ignore;
    raise (System_exit status)

let options (CommandObj (_, _, options)) = (options :> (Options.zi_option, _) opt_spec list)

let help (CommandObj (help, _, _)) = help

type commands = (string * node) list
and node =
  | Command of command
  | Group of commands

let make_command_hidden handler valid_options =
  Command (CommandObj (None, handler, valid_options))

let make_command help handler valid_options =
  Command (CommandObj (Some help, handler, valid_options))

let make_group subcommands =
  Group subcommands

let rec set_of_option_names = function
  | Command command ->
      let add s (names, _nargs, _help, _handler) = List.fold_right XString.Set.add names s in
      List.fold_left add XString.Set.empty (options command)
  | Group group ->
      group |> List.fold_left (fun set (_name, node) -> XString.Set.union set (set_of_option_names node)) XString.Set.empty

let rec lookup node args =
  match node, args with
  | Group items, name :: args ->
      let subnode = List.assoc_opt name items |? lazy (Safe_exn.failf "Unknown 0install sub-command '%s': try --help" name) in
      let prefix, node, args = lookup subnode args in
      (name :: prefix, node, args)
  | _ -> ([], node, args)
