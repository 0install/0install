(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Helpers for dealing with URLs. *)

(* Note: Ocamlnet has a Neturl package which does all this, but it's too big for us.
 * This is just enough for 0install: we support only http:, https: and ftp: schemes. *)

(* "http://host:port/path?query" -> ("http://host:port", "/path?query")
 * A missing path is returned as "/" *)
val split_path : string -> (string * string)

(** [join_url base url] converts [url] to an absolute URL (if it isn't already), using
 * [base] as the base. *)
val join_url : string -> string -> string
