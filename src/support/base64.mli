(* Copyright (C) 2017, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Base64 decoder. This is only used for GPG signatures - performance is not important. *)

exception Invalid_char

val str_decode : string -> string
