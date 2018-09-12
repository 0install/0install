(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Environment variables (generic support code) *)

open Support.Common

type t

val empty : t
val put : varname -> string -> t -> t
val get : varname -> t -> string option
val get_exn : varname -> t -> string
val unset : varname -> t -> t

val of_array : string array -> t
val to_array : t -> string array
