(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing version numbers *)

type modifier =
  | Pre
  | Rc
  | Dash
  | Post

type dotted_int = Int64.t list

type t = (dotted_int * modifier) list

type version_expr = t -> bool

(** Convert a version string to an internal representation.
    The parsed format can be compared using the regular comparison operators.
     - Version := DottedList ("-" Mod DottedList?)*
     - DottedList := (Integer ("." Integer)* )
    @raise Safe_exn.T if the string isn't a valid version
 *)
val parse : string -> t
val to_string : t -> string

(** [make_range_restriction x y] returns a test for versions where [x <= version < y]. *)
val make_range_restriction : string option -> string option -> version_expr

(** [parse_expr expr] is a test for versions that match [expr].
 * e.g. [parse_expr "2.2..!3 | 3.3.."] matches [2.3.1] and [3.3.2] but not [3.1]. *)
val parse_expr : string -> version_expr

(** Remove everything from the first "-" *)
val strip_modifier : t -> t

(** Try to turn a distribution version string into a 0install one.
    We do this by ignoring anything we can't parse, with some additional heuristics. *)
val try_cleanup_distro_version : string -> t option

(** Formatter for [%a] format strings. *)
val pp : Format.formatter -> t -> unit
