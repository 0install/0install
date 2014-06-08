(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing command-line arguments *)

val common_options :
  ([> `DryRun
    | `Help
    | `UseGUI of Support.Common.yes_no_maybe
    | `Verbose
    | `WithStore of Support.Common.filepath ],
   Options.zi_arg_type)
  Support.Argparse.opt_spec list

val commands : Command_tree.commands
val store_commands : Command_tree.commands

val no_command : Command_tree.node

val spec : (Options.zi_option, Options.zi_arg_type) Support.Argparse.argparse_spec
val get_default_options : Zeroinstall.General.config -> Options.global_settings
val handle : Zeroinstall.General.config -> string list -> unit
