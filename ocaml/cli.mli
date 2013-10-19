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

type subcommand =
   < handle : Options.global_settings ->
              Support.Argparse.raw_option list ->
              string list ->      (* Command path e.g. ["store"; "add"] for "0install store add" *)
              string list ->      (* Arguments (after command path) *)
              unit;
     help : string;
     options : (Options.zi_option, Options.zi_arg_type) Support.Argparse.opt_spec
               list >
and subgroup = (string * subnode) list
and subnode =
  | Subcommand of subcommand
  | Subgroup of subgroup

val subcommands : subgroup

val no_command : subcommand
val set_of_option_names : subnode -> Support.Common.StringSet.t
val handle : Zeroinstall.General.config -> string list -> unit

val spec : (Options.zi_option, Options.zi_arg_type) Support.Argparse.argparse_spec
val get_default_options : Zeroinstall.General.config -> Options.global_settings
