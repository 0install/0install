(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Support.Common

type version = string

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
  | RequireVersionFor of iface_uri * version

  | ShowXML
  | ShowFullDiff
  | ShowRoot
  | ShowHuman

  | UseHash of string
  | ShowManifest
  | ShowDigest

  | MainExecutable of string

  | Background

  | AmbiguousOption of (string -> zi_option)

type global_settings = {
  config : Zeroinstall.General.config;
  distro : Zeroinstall.Distro.distribution Lazy.t;
  mutable gui : yes_no_maybe;
  mutable verbosity : int;
  mutable extra_options : zi_option Support.Argparse.option_value list;
  mutable extra_stores : filepath list;
  mutable args : string list;
}
