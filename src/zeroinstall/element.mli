(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Type-safe access to the XML formats.
 * See:
 * http://0install.net/interface-spec.html
 * http://0install.net/selections-spec.html
 *
 * Internally, all [_ t] types are just [Support.Qdom.element], but we add a
 * phantom type parameter to avoid mix-ups. e.g. a [[`Command] t] is an element
 * that we know is a <command>.
 *
 * The type parameter is a polymorphic variant because many commands work on
 * multiple element types. For example, many elements have an 'interface'
 * attribute, so the [interface] function accepts multiple types. *)

open Support.Common

type +'a t

type binding_node =
  [ `Environment | `Executable_in_path | `Executable_in_var | `Binding]

type binding =
  [ `Environment of [`Environment] t
  | `Executable_in_path of [`Executable_in_path] t
  | `Executable_in_var of [`Executable_in_var] t
  | `Binding of [`Binding] t ]

type dependency_node = [ `Requires | `Restricts | `Runner ]

type dependency =
  [ `Requires of [`Requires] t
  | `Restricts of [`Restricts] t
  | `Runner of [`Runner] t]

type attr_node =
  [ `Group
  | `Implementation
  | `Compile_impl
  | `Package_impl ]

(** {2 Selections} *)

val parse_selections : Support.Qdom.element -> [`Selections] t
val selections : [`Selections] t -> [`Selection] t list

val local_path : [`Selection] t -> filepath option
val deps_and_bindings : [< `Selection | attr_node] t ->
  [> `Requires of [> `Requires] t
   | `Restricts of [> `Restricts] t
   | `Command of [`Command] t
   | binding ] list
val arch : [< `Selection | `Feed_import | `Compile_impl] t -> string option
val id : [< `Selection | `Implementation] t -> string
val version : [`Selection] t -> string
val version_opt : [< `Selection | `Package_impl | dependency_node] t -> string option   (* Messy: `Selection only for failed solves *)
val compile_min_version : [`Selection] t -> string option
val doc_dir : [`Selection] t -> filepath option
val source : [< `Selections | dependency_node] t -> bool option
val requires_compilation : [`Selection] t -> bool option

(** {2 Feeds} *)
val parse_feed : Support.Qdom.element -> [`Feed] t

(** Remove any elements with non-matching if-install-version attributes.
 * Note: parse_feed calls this automatically for you. *)
val filter_if_0install_version : 'a t -> 'a t option

val uri : [`Feed] t -> string option
val uri_exn : [`Feed] t -> string
val feed_metadata : [`Feed] t ->
  [ `Name of [`Name] t
  | `Replaced_by of [`Replaced_by] t
  | `Feed_for of [`Feed_for] t
  | `Category of [`Category] t
  | `Needs_terminal of [`Needs_terminal] t
  | `Homepage of [`Homepage] t
  | `Icon of [`Icon] t
  | `Feed_import of [`Feed_import] t
  ] list
val langs : [< `Feed_import] t -> string option
val src : [< `Feed_import] t -> string
val group_children : [< `Feed | `Group] t ->
  [ `Group of [`Group] t
  | `Implementation of [`Implementation] t
  | `Package_impl of [`Package_impl] t
  ] list

(** Note: main on `Feed is deprecated *)
val main : [< `Feed | attr_node] t -> string option
val self_test : [< attr_node] t -> string option
val compile_command : [< attr_node] t -> string option
val retrieval_methods : [`Implementation] t -> [`Archive | `File | `Recipe] t list
val classify_retrieval : [`Archive | `File | `Recipe] t ->
  [ `Archive of [`Archive] t
  | `File of [`File] t
  | `Recipe of [`Recipe] t ]
val dest_opt : [`Archive] t -> filepath option
val dest : [< `File | `Rename] t -> filepath
val executable : [< `File] t -> bool option
val extract : [`Archive] t -> filepath option
val start_offset : [`Archive] t -> int64 option
val mime_type : [`Archive] t -> string option
val remove_path : [`Remove] t -> string
val size : [< `Archive | `File] t -> int64

val recipe_steps : [`Recipe] t -> [
    | `Archive of [`Archive] t
    | `File of [`File] t
    | `Rename of [`Rename] t
    | `Remove of [`Remove] t
  ] list option
(** [recipe_steps e] is the steps of the recipe if we recognise every child with a 0install namespace,
    or [None] if there are unknown step types. *)

val href : [< `Archive | `File | `Icon] t -> string
val rename_source : [`Rename] t -> filepath
val icon_type : [`Icon] t -> string option
val distributions : [< `Package_impl] t -> string option

(** {2 Commands} *)

(** Find the <runner> child of this element (selection or command), if any.
 * @raise Safe_exn.T if there are multiple runners. *)
val get_runner : [`Command] t -> [`Runner] t option
val make_command : ?path:filepath -> ?shell_command:string -> source_hint:'a t option -> string -> [`Command] t
val get_command : string -> [`Selection] t -> [`Command] t option
val get_command_ex : string -> [`Selection] t -> [`Command] t
val path : [`Command] t -> filepath option
val arg_children : [< `Command | `Runner | `For_each] t -> [`Arg of [`Arg] t | `For_each of [> `For_each] t] list
val item_from : [`For_each] t -> string
val separator : [< `For_each | `Environment] t -> string option
val command : [< `Runner | `Binding | `Executable_in_path | `Executable_in_var | `Selections] t -> string option
val command_children : [`Command] t -> [> dependency | binding ] list
val command_name : [`Command] t -> string
val simple_content : [< `Name | `Arg | `Category | `Homepage] t -> string

(** The first <compile:implementation> element. *)
val compile_template : [`Command] t -> [> `Compile_impl] t option
val compile_include_binary : [< dependency_node] t -> bool option

(** {2 Feeds and interfaces} *)
val interface :
  [< `Selections | `Selection | `Requires | `Restricts | `Runner | `Replaced_by | `Feed_for] t -> Sigs.iface_uri
val from_feed : [`Selection] t -> string option

(** {2 Implementations} *)
val make_impl : ?source_hint:Support.Qdom.element -> ?child_nodes:Support.Qdom.element list -> Support.Qdom.AttrMap.t -> [> `Implementation] t

(** Copy element with a new interface. Used to make relative paths absolute. *)
val with_interface : Sigs.iface_uri -> ([< dependency_node] t as 'a) -> 'a

(** {2 Dependencies} *)
val importance : [< `Requires | `Runner] t -> [> `Essential | `Recommended]
val classify_dep : [< `Requires | `Restricts | `Runner] t ->
  [ `Requires of [> `Requires] t
  | `Restricts of [> `Restricts] t
  | `Runner of [> `Runner] t]

val restrictions : [< `Requires | `Restricts | `Runner] t -> [`Version of [`Version] t] list
val before : [`Version] t -> string option
val not_before : [`Version] t -> string option
val os : [< dependency_node] t -> Arch.os option
val use : [< dependency_node] t -> string option
val distribution : [< dependency_node] t -> string option
val element_of_dependency : dependency -> dependency_node t
val dummy_restricts : [> `Restricts] t

(** {2 Bindings} *)
val bindings : [< `Selection | `Command | `Requires | `Restricts | `Runner] t -> binding list
val binding_name : [< `Environment | `Executable_in_path | `Executable_in_var] t -> string
val element_of_binding : binding -> binding_node t
val classify_binding : [< binding_node] t -> binding
val insert : [`Environment] t -> string option
val value : [`Environment] t -> string option
val mode : [`Environment] t -> string option
val default : [`Environment] t -> string option

(** {2 Distribution packages} *)
val package : [< `Selection | `Package_impl] t -> string
val quick_test_file : [`Selection] t -> filepath option
val quick_test_mtime : [`Selection] t -> int64 option

(** {2 Error reporting} *)

(** [raise_elem "Problem with" elem] raises a [Safe_exn.T] with the message "Problem with <element> at ..." *)
val raise_elem : ('a, unit, string, _ t -> 'b) format4 -> 'a

(** Like [raise_elem], but writing a log record rather than raising an exception. *)
val log_elem : Support.Logging.level -> ('a, unit, string, _ t -> unit) format4 -> 'a

(** Format a string identifying this element for use in error messages. Includes the source location, if known. *)
val pp : Format.formatter -> _ t -> unit

val as_xml : _ t -> Support.Qdom.element

val get_summary : int Support.Locale.LangMap.t -> [`Feed] t -> string option
val get_description : int Support.Locale.LangMap.t -> [`Feed] t -> string option
