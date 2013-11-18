(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Access to the rest of the system. This capabilities are provided via an object, which can be replaced for unit-testing.  *)

module type UnixType = module type of Unix

val wrap_unix_errors : (unit -> 'a) -> 'a
val check_exit_status : Unix.process_status -> unit
val waitpid_non_intr : int -> int * Unix.process_status
val reap_child : int -> unit

val canonical_machine : string -> string
val canonical_os : string -> string

val dev_null : Common.filepath

module RealSystem :
  functor (U : UnixType) ->
    sig
      class real_system : Common.system
    end
