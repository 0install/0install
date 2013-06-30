(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

type version = string

type network_use = Offline

type yes_no_maybe = Yes | No | Maybe

type zi_option =
  (* common options *)
  | UseGUI of yes_no_maybe
  | Verbose
  | Help
  | DryRun
  | WithStore of string
  | Wrapper of string
  | ShowVersion

  (* select options *)
  | Before of version
  | NotBefore of version
  | WithMessage of string
  | NetworkUse of network_use
  | SelectCommand of string
  | Cpu of string
  | Os of string
  | Refresh
  | Source
  | RequireVersion of version
  | RequireVersionFor of string * version

  | ShowXML
  | ShowFullDiff
  | ShowRoot
  | ShowHuman

  | UseHash of string
  | ShowManifest
  | ShowDigest

  | MainExecutable of string

type global_settings = {
  config : General.config;
  mutable gui : yes_no_maybe;
  mutable dry_run : bool;
  mutable verbosity : int;
  mutable extra_options : zi_option Support.Argparse.option_value list;
  mutable args : string list;
}
