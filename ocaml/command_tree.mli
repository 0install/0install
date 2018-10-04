(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Directory of command handlers (e.g. ["store"; "add"] -> Store.handle_add) *)

open Options
open Support
open Support.Argparse

type command
and commands = (string * node) list
and node =
  | Command of command
  | Group of commands

(** A handler for a command, accepting options of type ['a] *)
type 'a handler = global_settings -> ([< zi_option ] as 'a) parsed_options -> string list -> unit

(** Parse the options and run the appropriate handler. *)
val handle :
  command ->
  global_settings ->
  raw_option list ->
  string list ->      (* Command path e.g. ["store"; "add"] for "0install store add" *)
  string list ->      (* Arguments (after command path) *)
  unit

(** Get the help text for this command. None if this is a hidden (internal) command. *)
val help : command -> string option

(** Get the list of options supported by this command. For tab-completion. *)
val options : command -> (zi_option, zi_arg_type) opt_spec list

(** Return the supported option names as a set (for tab-completion). *)
val set_of_option_names : node -> XString.Set.t

val make_command :
  string -> (* help text *)
  'a handler ->
  ('a, zi_arg_type) opt_spec list ->
  node

val make_command_hidden :
  'a handler ->
  ('a, zi_arg_type) opt_spec list ->
  node

val make_group : commands -> node

val lookup :
  node ->
  string list ->  (* args *)
  string list * node * string list  (* consumed args, node, remaining args *)
