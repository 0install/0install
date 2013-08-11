(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Useful constants and utilities to be [open]ed by all modules. *)

(** {2 Types} *)

exception Fallback_to_Python

open Support.Common

exception Safe_exception = Support.Common.Safe_exception

(** A URI used to identify an interface. Uses only plain URI characters, unicode chars, spaces, etc are %-escaped. *)
type iface_uri = string

module StringMap = Support.Common.StringMap

type network_use = Full_network | Minimal_network | Offline

type config = {
  basedirs: Support.Basedir.basedirs;
  mutable stores: string list;
  abspath_0install: filepath;

  mutable system : Support.Common.system;

  mutable freshness: Int64.t option;
  mutable dry_run : bool;
  mutable network_use : network_use;
}

(** {2 Utility functions} *)

(** {2 Useful constants} *)

let hours = 60 * 60         (* Seconds per hour *)

let days = 24 * hours       (* Seconds per day *)

let re_colon = Str.regexp_string ":"
let re_equals = Str.regexp_string "="
let re_tab = Str.regexp_string "\t"

(** {2 Relative configuration paths (e.g. under ~/.config)} *)

let config_site = "0install.net"
let config_prog = "injector"
let config_injector_interfaces = config_site +/ config_prog +/ "interfaces"
let config_injector_global = config_site +/ config_prog +/ "global"

let data_site_packages = config_site +/ "site-packages"     (* 0compile builds, etc *)
let data_native_feeds = config_site +/ "native_feeds"       (* Feeds provided by distribution packages (rare) *)

(** {2 The 0install XML namespace} *)

module ZI_NS = struct
  let ns = "http://zero-install.sourceforge.net/2004/injector/interface";;
end

module ZI = Support.Qdom.NsQuery (ZI_NS)

type stability_level =
  | Insecure
  | Buggy
  | Developer
  | Testing
  | Stable
  | Packaged
  | Preferred
