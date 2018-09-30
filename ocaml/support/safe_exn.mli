(* Copyright (C) 2018, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A [Safe_exn.T] represents an error that is not a bug in 0install.
    It should be reported to the user without a stack trace by default. *)

type payload

exception T of payload
(** A [T _] is an exception with a main error message and a list of additional context lines. *)

val v : ?ctx:string list -> ('a, Format.formatter, unit, exn) format4 -> 'a
(** [v fmt ...] is a new [T] with [fmt ...] as its message. *)

val failf : ?ctx:string list -> ('a, Format.formatter, unit, _) format4 -> 'a
(** [failf fmt ...] raises a safe exception with the given message (and optional context). *)

val reraise_with : exn -> ('a, Format.formatter, unit, _) format4 -> 'a
(** [reraise_with exn fmt ...] adds [fmt ...] to the context of [exn] (which must be
    a [T]) and re-raises it, preserving the existing stack-trace. *)

val with_info : ((('a, Format.formatter, unit, unit) format4 -> 'a) -> unit) -> (unit -> 'r Lwt.t) -> 'r Lwt.t
(** [with_info note f] is [f ()], except that if it raises [T _] then
    we call [note writer] and add whatever is passed to writer to the context. *)

val pp : Format.formatter -> payload -> unit
(** [pp] formats a payload by writing out the message followed by each context line. *)

val msg : payload -> string
(** [msg p] is the message part of the payload (without the context) .*)
