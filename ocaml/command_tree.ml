(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Support.Common
open Support.Argparse

type 'a handler = Options.global_settings -> ([< Options.zi_option ] as 'a) parsed_options -> string list -> unit

let make_command_obj help handler valid_options =
  object
    method handle options raw_options command_path args =
      let flags = parse_options valid_options raw_options in
      try handler options flags args
      with Usage_error status ->
        let command = String.concat " " command_path in
        Common_options.show_help options.Options.config.system valid_options (command ^ " [OPTIONS] " ^ (help |> default "")) ignore;
        raise (System_exit status)

    method options = (valid_options :> (Options.zi_option, _) opt_spec list)
    method help = help
  end

let handle cmd = cmd#handle
let options cmd = cmd#options
let help cmd = cmd#help

type command =
   < handle : Options.global_settings -> raw_option list -> string list -> string list -> unit;
     help : string option;
     options : (Options.zi_option, Options.zi_arg_type) opt_spec list >
and commands = (string * node) list
and node =
  | Command of command
  | Group of commands

let make_command_hidden handler valid_options =
  Command (make_command_obj None handler valid_options)

let make_command help handler valid_options =
  Command (make_command_obj (Some help) handler valid_options)

let make_group subcommands =
  Group subcommands

let rec set_of_option_names = function
  | Command command ->
      let add s (names, _nargs, _help, _handler) = List.fold_right StringSet.add names s in
      List.fold_left add StringSet.empty command#options
  | Group group ->
      group |> List.fold_left (fun set (_name, node) -> StringSet.union set (set_of_option_names node)) StringSet.empty

let assoc key items =
  try Some (List.assoc key items)
  with Not_found -> None

let rec lookup node args =
  match node, args with
  | Group items, name :: args ->
      let subnode = assoc name items |? lazy (raise_safe "Unknown 0install sub-command '%s': try --help" name) in
      let prefix, node, args = lookup subnode args in
      (name :: prefix, node, args)
  | _ -> ([], node, args)
