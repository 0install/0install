(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Environment variables (generic support code) *)

type t

type name = string

val empty : t
val put : name -> string -> t -> t
val get : name -> t -> string option
val get_exn : name -> t -> string
val unset : name -> t -> t

val of_array : string array -> t
val to_array : t -> string array
