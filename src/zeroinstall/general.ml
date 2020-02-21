(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Useful constants and utilities to be [open]ed by all modules. *)

(** {2 Types} *)

open Support.Common

type network_use = Full_network | Minimal_network | Offline

type config = {
  paths : Paths.t;
  mutable stores: filepath list;
  mutable extra_stores: filepath list;      (* (subset of stores; passed to Python slave with --with-store) *)
  abspath_0install: filepath;

  system : Support.Common.system;

  mutable mirror : string option;
  mutable key_info_server : string option;
  mutable freshness: float option;
  mutable dry_run : bool;
  mutable network_use : network_use;
  mutable help_with_testing : bool;
  mutable auto_approve_keys : bool;
  
  langs : int Support.Locale.LangMap.t;
}

(** {2 Useful constants} *)

let hours = 60. *. 60.         (* Seconds per hour *)

let days = 24. *. hours       (* Seconds per day *)

(** {2 The 0install XML namespace} *)

module ZI_NS = struct
  let ns = "http://zero-install.sourceforge.net/2004/injector/interface"
  let prefix_hint = "zi"
end

module ZI = Support.Qdom.NsQuery (ZI_NS)

module COMPILE_NS = struct
  let ns = "http://zero-install.sourceforge.net/2006/namespaces/0compile"
  let prefix_hint = "compile"
end
