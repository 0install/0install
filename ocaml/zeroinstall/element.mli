(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Type-safe access to the XML formats.
 * See:
 * http://0install.net/interface-spec.html
 * http://0install.net/selections-spec.html
 *
 * Internally, all [_ t] types are just [Support.Qdom.element], but we add a
 * phantom type parameter to avoid mix-ups. e.g. a [[`command] t] is an element
 * that we know is a <command>.
 *
 * The type parameter is a polymorphic variant because many commands work on
 * multiple element types. For example, many elements have an 'interface'
 * attribute, so the [interface] function accepts multiple types. *)

open Support.Common

type +'a t

type binding =
  [ `environment of [`environment] t
  | `executable_in_path of [`executable_in_path] t
  | `executable_in_var of [`executable_in_var] t
  | `binding of [`binding] t ]

type dependency =
  [ `requires of [`requires] t
  | `restricts of [`restricts] t
  | `runner of [`runner] t]

(** {2 Selections} *)

val parse_selections : Support.Qdom.element -> [`selections] t
val selections : [`selections] t -> [`selection] t list

val local_path : [`selection] t -> filepath option
val selection_children : [`selection] t ->
  [> `requires of [`requires] t
   | `restricts of [`restricts] t
   | `command of [`command] t
   | binding ] list
val arch : [`selection] t -> string option
val id : [`selection] t -> string
val version : [`selection] t -> string
val version_opt : [`selection] t -> string option   (* Messy: only for failed solves *)
val compile_min_version : [`selection] t -> string option
val doc_dir : [`selection] t -> filepath option

(** {2 Commands} *)

(** Find the <runner> child of this element (selection or command), if any.
 * @raise Safe_exception if there are multiple runners. *)
val get_runner : [`command] t -> [`runner] t option
val make_command : source_hint:'a t option -> [`command] t
val get_command : string -> [`selection] t -> [`command] t option
val get_command_ex : string -> [`selection] t -> [`command] t
val path : [`command] t -> filepath option
val arg_children : [< `command | `runner | `for_each] t -> [`arg of [`arg] t | `for_each of [> `for_each] t] list
val item_from : [`for_each] t -> string
val separator : [`for_each] t -> string option
val command : [< `runner | `executable_in_path | `executable_in_var | `selections] t -> string option
val command_children : [`command] t ->
  [> `requires of [`requires] t
   | `restricts of [`restricts] t
   | `runner of [`runner] t
   | binding ] list
val command_name : [`command] t -> string
val simple_content : [`arg] t -> string

(** {2 Feeds and interfaces} *)
val interface : [< `selections | `selection | `requires | `restricts | `runner] t -> General.iface_uri
val from_feed : [`selection] t -> string option

(** {2 Dependencies} *)
val importance : [< `requires | `runner] t -> [> `essential | `recommended]
val classify_dep : [< `requires | `restricts | `runner] t -> dependency

(** {2 Bindings} *)
val bindings : [< `selection | `command | `requires | `restricts | `runner] t -> binding list
val binding_name : [< `environment | `executable_in_path | `executable_in_var] t -> string

(** {2 Distribution packages} *)
val package : [`selection] t -> string
val quick_test_file : [`selection] t -> filepath option
val quick_test_mtime : [`selection] t -> int64 option

(** {2 Error reporting} *)

(** [raise_elem "Problem with" elem] raises a [Safe_exception] with the message "Problem with <element> at ..." *)
val raise_elem : ('a, unit, string, _ t -> 'b) format4 -> 'a

(** Like [raise_elem], but writing a log record rather than raising an exception. *)
val log_elem : Support.Logging.level -> ('a, unit, string, _ t -> unit) format4 -> 'a

val as_xml : _ t -> Support.Qdom.element
