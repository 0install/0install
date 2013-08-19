(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Support.Common

type version = string

type common_option = [
  (* common options *)
  | `UseGUI of yes_no_maybe
  | `Verbose
  | `Help
  | `DryRun
  | `WithStore of string
  | `ShowVersion
  | `NetworkUse of network_use
]

type version_restriction_option = [
  | `Before of version
  | `NotBefore of version
  | `RequireVersion of version
  | `RequireVersionFor of iface_uri * version
]

type other_req_option = [
  | `WithMessage of string
  | `SelectCommand of string
  | `Cpu of string
  | `Os of string
  | `Source
]

type select_option = [
  | version_restriction_option
  | other_req_option
]

type generic_select_option = [
  | `Refresh
  | `ShowHuman
  | `ShowXML
]

type zi_option = [
  | common_option
  | select_option
  | generic_select_option

  | `ShowFullDiff
  | `ShowRoot

  | `UseHash of string
  | `ShowManifest
  | `ShowDigest

  | `MainExecutable of string
  | `Wrapper of string

  | `Background
]

type global_settings = {
  config : Zeroinstall.General.config;
  slave : Zeroinstall.Python.slave;
  distro : Zeroinstall.Distro.distribution Lazy.t;
  mutable gui : yes_no_maybe;
  mutable verbosity : int;
}

type zi_arg_type =
  | Dir
  | ImplRelPath
  | Command
  | VersionRange
  | SimpleVersion
  | CpuType | OsType
  | Message
  | HashType
  | IfaceURI
