
(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Implementation mode *)

type t = [`immediate | `requires_compilation]
val to_string : t -> string
val parse : string -> t
