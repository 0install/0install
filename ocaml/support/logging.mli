(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Simple logging support *)

type level = Debug | Info | Warning

val string_of_level : level -> string

val threshold : level ref

val will_log : level -> bool

class type handler =
  object
    method handle : ?ex:exn -> level -> string -> unit
  end

val handler : handler ref

(* [fmt] has type ('a, unit, string, unit) format4, which means:
   - we accept any a format with variables type (e.g. "got:%s" has type string -> unit)
   - any custom print function passed by the caller has type unit -> string
   - the final result of the whole thing is unit
 *)
val log : level -> ?ex:exn -> ('a, unit, string, unit) format4 -> 'a

val log_debug : ('a, unit, string, unit) format4 -> 'a

(** Write a message to stderr if verbose logging is on. *)
val log_info : ?ex:exn -> ('a, unit, string, unit) format4 -> 'a

(** Write a message to stderr, prefixed with "warning: ". *)
val log_warning  : ?ex:exn -> ('a, unit, string, unit) format4 -> 'a

val format_argv_for_logging : string list -> string
