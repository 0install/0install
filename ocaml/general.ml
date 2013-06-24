(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Useful constants and utilities to be [open]ed by all modules. *)

(** {2 Types} *)

exception Fallback_to_Python

type filepath = Support.filepath

exception Safe_exception = Support.Safe_exception

module StringMap = Support.StringMap

type config = {
  basedirs: Basedir.basedirs;
  stores: string list;
  abspath_0install: filepath;
  freshness: int option;
}

(** {2 Utility functions} *)

let (+/) = Filename.concat

let raise_safe = Support.raise_safe

let default = Support.default

let reraise_with_context = Support.reraise_with_context

let log_info = Logging.log_info
let log_warning = Logging.log_warning

let starts_with = Support.starts_with

(** {2 Useful 0install constants} *)

let path_sep = Support.path_sep

let hours = 60 * 60         (* Seconds per hour *)

let days = 24 * hours       (* Seconds per day *)

(** {2 The 0install XML namespace} *)

module ZI_NS = struct
  let ns = "http://zero-install.sourceforge.net/2004/injector/interface";;
end

module ZI = Qdom.NsQuery (ZI_NS)
