(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General

type version = string

type common_option = [
  (* common options *)
  | `UseGUI of [`Yes | `No | `Auto]
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
  | `RequireVersionFor of Zeroinstall.Sigs.iface_uri * version
]

type other_req_option = [
  | `WithMessage of string
  | `SelectCommand of string
  | `Cpu of string
  | `Os of string
  | `Source
]

type binary_select_option = [
  | version_restriction_option
  | other_req_option
]

type select_option = [
  | binary_select_option
  | `MayCompile
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

type tools = <
  config : Zeroinstall.General.config;
  ui : Zeroinstall.Ui.ui_handler;
  download_pool : Zeroinstall.Downloader.download_pool;
  distro : Zeroinstall.Distro.t;
  make_fetcher : Zeroinstall.Progress.watcher -> Zeroinstall.Fetch.fetcher;
  trust_db : Zeroinstall.Trust.trust_db;
  set_use_gui : [`Yes | `No | `Auto] -> unit;
  use_gui : [`Yes | `No | `Auto];
  release : unit;     (* Call this to release any open connections held by the download pool. *)
>

type global_settings = {
  config : Zeroinstall.General.config;
  tools : tools;
  mutable verbosity : int;
}

type zi_arg_type =
  | Dir
  | ImplRelPath
  | CommandName
  | VersionRange
  | SimpleVersion
  | CpuType | OsType
  | Message
  | HashType
  | IfaceURI
