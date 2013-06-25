(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Useful constants and utilities to be [open]ed by all modules. *)

(** {2 Types} *)

exception Fallback_to_Python

type filepath = Support.filepath

exception Safe_exception = Support.Safe_exception

class type distribution =
  object
    (** Test whether this <selection> element is still valid *)
    method is_installed : Qdom.element -> bool
  end;;

module StringMap = Support.StringMap

type config = {
  basedirs: Basedir.basedirs;
  stores: string list;
  abspath_0install: filepath;

  distro: distribution Lazy.t;
  system : Support.system;

  mutable freshness: int option;
}

(** {2 Utility functions} *)

let (+/) = Filename.concat

let raise_safe = Support.raise_safe

let default = Support.default

let reraise_with_context = Support.reraise_with_context

let log_info = Logging.log_info
let log_warning = Logging.log_warning

let starts_with = Support.starts_with

(** {2 Useful constants} *)

let path_sep = Support.path_sep

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

(** {2 The 0install XML namespace} *)

module ZI_NS = struct
  let ns = "http://zero-install.sourceforge.net/2004/injector/interface";;
end

module ZI = Qdom.NsQuery (ZI_NS)
