(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Useful constants and utilities to be [open]ed by all modules. *)

(** {2 Types} *)

open Support.Common

(** A URI used to identify an interface. Uses only plain URI characters, unicode chars, spaces, etc are %-escaped. *)
type iface_uri = string

type feed_url = string

type network_use = Full_network | Minimal_network | Offline

type config = {
  basedirs: Support.Basedir.basedirs;
  mutable stores: filepath list;
  mutable extra_stores: filepath list;      (* (subset of stores; passed to Python slave with --with-store) *)
  abspath_0install: filepath;

  mutable system : Support.Common.system;

  mutable mirror : string option;
  mutable freshness: Int64.t option;
  mutable dry_run : bool;
  mutable network_use : network_use;
  mutable help_with_testing : bool;
  
  langs : int Support.Locale.LangMap.t;
}

(** {2 Utility functions} *)

(** {2 Useful constants} *)

let hours = 60 * 60         (* Seconds per hour *)

let days = 24 * hours       (* Seconds per day *)

(** {2 Relative configuration paths (e.g. under ~/.config)} *)

let config_site = "0install.net"
let config_prog = "injector"
let config_injector_interfaces = config_site +/ config_prog +/ "interfaces"
let config_injector_global = config_site +/ config_prog +/ "global"
let config_trust_db = config_site +/ config_prog +/ "trustdb.xml"

let data_site_packages = config_site +/ "site-packages"     (* 0compile builds, etc *)
let data_native_feeds = config_site +/ "native_feeds"       (* Feeds provided by distribution packages (rare) *)

let cache_last_check_attempt = config_site +/ config_prog +/ "last-check-attempt"

(** {2 The 0install XML namespace} *)

module ZI_NS = struct
  let ns = "http://zero-install.sourceforge.net/2004/injector/interface";;
end

module ZI = Support.Qdom.NsQuery (ZI_NS)

module COMPILE_NS = struct
  let ns = "http://zero-install.sourceforge.net/2006/namespaces/0compile"
end

let xml_ns = "http://www.w3.org/XML/1998/namespace"

type stability_level =
  | Insecure
  | Buggy
  | Developer
  | Testing
  | Stable
  | Packaged
  | Preferred
