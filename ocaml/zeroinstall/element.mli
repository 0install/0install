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

type binding_node =
  [ `environment | `executable_in_path | `executable_in_var | `binding]

type binding =
  [ `environment of [`environment] t
  | `executable_in_path of [`executable_in_path] t
  | `executable_in_var of [`executable_in_var] t
  | `binding of [`binding] t ]

type dependency_node = [ `requires | `restricts | `runner ]

type dependency =
  [ `requires of [`requires] t
  | `restricts of [`restricts] t
  | `runner of [`runner] t]

type attr_node =
  [ `group
  | `implementation
  | `compile_impl
  | `package_impl ]

(** {2 Selections} *)

val parse_selections : Support.Qdom.element -> [`selections] t
val selections : [`selections] t -> [`selection] t list

val local_path : [`selection] t -> filepath option
val deps_and_bindings : [< `selection | attr_node] t ->
  [> `requires of [> `requires] t
   | `restricts of [> `restricts] t
   | `command of [`command] t
   | binding ] list
val arch : [< `selection | `feed_import | `compile_impl] t -> string option
val id : [< `selection | `implementation] t -> string
val version : [`selection] t -> string
val version_opt : [< `selection | dependency_node] t -> string option   (* Messy: `selection only for failed solves *)
val compile_min_version : [`selection] t -> string option
val doc_dir : [`selection] t -> filepath option
val source : [< `selections | dependency_node] t -> bool option
val requires_compilation : [`selection] t -> bool option

(** {2 Feeds} *)
val parse_feed : Support.Qdom.element -> [`feed] t

(** Remove any elements with non-matching if-install-version attributes.
 * Note: parse_feed calls this automatically for you. *)
val filter_if_0install_version : 'a t -> 'a t option

val uri : [`feed] t -> string option
val uri_exn : [`feed] t -> string
val feed_metadata : [`feed] t ->
  [ `name of [`name] t
  | `replaced_by of [`replaced_by] t
  | `feed_for of [`feed_for] t
  | `category of [`category] t
  | `needs_terminal of [`needs_terminal] t
  | `homepage of [`homepage] t
  | `icon of [`icon] t
  | `feed_import of [`feed_import] t
  ] list
val langs : [< `feed_import] t -> string option
val src : [< `feed_import] t -> string
val group_children : [< `feed | `group] t ->
  [ `group of [`group] t
  | `implementation of [`implementation] t
  | `package_impl of [`package_impl] t
  ] list

(** Note: main on `feed is deprecated *)
val main : [< `feed | attr_node] t -> string option
val self_test : [< attr_node] t -> string option
val compile_command : [< attr_node] t -> string option
val retrieval_methods : [`implementation] t -> Support.Qdom.element list
val href : [`icon] t -> string
val icon_type : [`icon] t -> string option
val distributions : [< `package_impl] t -> string option

(** {2 Commands} *)

(** Find the <runner> child of this element (selection or command), if any.
 * @raise Safe_exception if there are multiple runners. *)
val get_runner : [`command] t -> [`runner] t option
val make_command : ?path:filepath -> ?shell_command:string -> source_hint:'a t option -> string -> [`command] t
val get_command : string -> [`selection] t -> [`command] t option
val get_command_ex : string -> [`selection] t -> [`command] t
val path : [`command] t -> filepath option
val arg_children : [< `command | `runner | `for_each] t -> [`arg of [`arg] t | `for_each of [> `for_each] t] list
val item_from : [`for_each] t -> string
val separator : [< `for_each | `environment] t -> string option
val command : [< `runner | `binding | `executable_in_path | `executable_in_var | `selections] t -> string option
val command_children : [`command] t -> [> dependency | binding ] list
val command_name : [`command] t -> string
val simple_content : [< `name | `arg | `category | `homepage] t -> string

(** The first <compile:implementation> element. *)
val compile_template : [`command] t -> [> `compile_impl] t option
val compile_include_binary : [< dependency_node] t -> bool option

(** {2 Feeds and interfaces} *)
val interface :
  [< `selections | `selection | `requires | `restricts | `runner | `replaced_by | `feed_for] t -> General.iface_uri
val from_feed : [`selection] t -> string option

(** {2 Implementations} *)
val make_impl : ?source_hint:Support.Qdom.element -> ?child_nodes:Support.Qdom.element list -> Support.Qdom.AttrMap.t -> [> `implementation] t

(** Copy element with a new interface. Used to make relative paths absolute. *)
val with_interface : General.iface_uri -> ([< dependency_node] t as 'a) -> 'a

(** {2 Dependencies} *)
val importance : [< `requires | `runner] t -> [> `essential | `recommended]
val classify_dep : [< `requires | `restricts | `runner] t ->
  [ `requires of [> `requires] t
  | `restricts of [> `restricts] t
  | `runner of [> `runner] t]

val restrictions : [< `requires | `restricts | `runner] t -> [`version of [`version] t] list
val before : [`version] t -> string option
val not_before : [`version] t -> string option
val os : [< dependency_node] t -> Arch.os option
val use : [< dependency_node] t -> string option
val distribution : [< dependency_node] t -> string option
val element_of_dependency : dependency -> dependency_node t
val dummy_restricts : [> `restricts] t

(** {2 Bindings} *)
val bindings : [< `selection | `command | `requires | `restricts | `runner] t -> binding list
val binding_name : [< `environment | `executable_in_path | `executable_in_var] t -> string
val element_of_binding : binding -> binding_node t
val classify_binding : [< binding_node] t -> binding
val insert : [`environment] t -> string option
val value : [`environment] t -> string option
val mode : [`environment] t -> string option
val default : [`environment] t -> string option

(** {2 Distribution packages} *)
val package : [< `selection | `package_impl] t -> string
val quick_test_file : [`selection] t -> filepath option
val quick_test_mtime : [`selection] t -> int64 option

(** {2 Error reporting} *)

(** [raise_elem "Problem with" elem] raises a [Safe_exception] with the message "Problem with <element> at ..." *)
val raise_elem : ('a, unit, string, _ t -> 'b) format4 -> 'a

(** Like [raise_elem], but writing a log record rather than raising an exception. *)
val log_elem : Support.Logging.level -> ('a, unit, string, _ t -> unit) format4 -> 'a

(** Generate a string identifying this element for use in error messages. Includes the source location, if known. *)
val show_with_loc : _ t -> string

(** [sprintf "%a"] formatter that uses [show_with_loc]. *)
val fmt : unit -> _ t -> string

val as_xml : _ t -> Support.Qdom.element

val get_summary : int Support.Locale.LangMap.t -> [`feed] t -> string option
val get_description : int Support.Locale.LangMap.t -> [`feed] t -> string option
