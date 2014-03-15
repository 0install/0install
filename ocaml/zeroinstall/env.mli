(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Environment variables (generic support code) *)

open Support.Common

type t

val create : string array -> t
val put : t -> varname -> string -> unit
val get : t -> varname -> string option
val get_exn : t -> varname -> string
val unset : t -> varname -> unit
val to_array : t -> string array
