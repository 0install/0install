(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Simple logging support *)

type level = Debug | Info | Warning

type time = float

type entry = time * exn option * level * string

val string_of_level : level -> string

val threshold : level ref

val will_log : level -> bool

(* If set, we call this before logging anything and then set it to None. This is used to clear progress displays. *)
val clear_fn : (unit -> unit) option ref

type handler = ?ex:exn -> level -> string -> unit

val handler : handler ref

val log : level -> ?ex:exn -> ('a, Format.formatter, unit) format -> 'a

val log_debug : ?ex:exn -> ('a, Format.formatter, unit) format -> 'a

(** Write a message to stderr if verbose logging is on. *)
val log_info : ?ex:exn -> ('a, Format.formatter, unit) format -> 'a

(** Write a message to stderr, prefixed with "warning: ". *)
val log_warning  : ?ex:exn -> ('a, Format.formatter, unit) format -> 'a

val format_argv_for_logging : string list -> string

(** If set, record all log messages (at all levels) in memory and dump to this directory
 * on error. Useful for tracking down intermittent bugs. *)
val set_crash_logs_handler : (entry list -> unit) -> unit

(** Dump all recorded log entries to the crash handler set with [set_crash_handler].
 * If there is no handler, or the log is empty, does nothing. This is called automatically
 * after logging at level Warning. *)
val dump_crash_log : ?ex:exn -> unit -> unit
