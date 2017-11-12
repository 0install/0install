(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** An implementation represents a single concrete implementation of an interface.
 * There can be several implementations with the same version number (e.g. for different
 * architectures, languages or ABIs). *)

(** {2 Types} **)

type importance =
  [ `Essential       (* Must select a version of the dependency *)
  | `Recommended     (* Prefer to select a version, if possible *)
  | `Restricts ]     (* Just adds restrictions without expressing any opinion *)

type distro_retrieval_method = {
  distro_size : Int64.t option;
  distro_install_info : (string * string);        (* In some format meaningful to the distribution *)
}

type package_state =
  [ `Installed
  | `Uninstalled of distro_retrieval_method ]

type package_impl = {
  package_distro : string;
  mutable package_state : package_state;
}

type cache_impl = {
  digests : Manifest.digest list;
  retrieval_methods : [`Archive | `File | `Recipe] Element.t list;
}

type existing =
  [ `Cache_impl of cache_impl
  | `Local_impl of Support.Common.filepath
  | `Package_impl of package_impl ]

type impl_type =
  [ existing
  | `Binary_of of existing t ]

and restriction = < meets_restriction : impl_type t -> bool; to_string : string >
and dependency = {
  dep_qdom : Element.dependency_node Element.t;
  dep_importance : importance;
  dep_iface : Sigs.iface_uri;
  dep_src : bool;
  dep_restrictions : restriction list;
  dep_required_commands : string list;
  dep_if_os : Arch.os option;                (* The badly-named 'os' attribute *)
  dep_use : string option;                  (* Deprecated 'use' attribute *)
}
and command = {
  mutable command_qdom : [`Command] Element.t;  (* Mutable because of distro's [fixup_main] *)
  command_requires : dependency list;
  command_bindings : Element.binding_node Element.t list;
}
and properties = {
  attrs : Support.Qdom.AttrMap.t;
  requires : dependency list;
  bindings : Element.binding_node Element.t list;
  commands : command Support.Common.StringMap.t;
}
and +'a t = {
  qdom : [`Implementation | `Package_impl] Element.t;
  props : properties;
  stability : Stability.t;
  os : Arch.os option;                (* Required OS; the first part of the 'arch' attribute. None for '*' *)
  machine : Arch.machine option;      (* Required CPU; the second part of the 'arch' attribute. None for '*' *)
  parsed_version : Version.t;
  impl_type : 'a;
}

type generic_implementation = impl_type t
type distro_implementation = [ `Package_impl of package_impl ] t

val make :
  elem : [< `Implementation | `Package_impl] Element.t ->
  props : properties ->
  stability : Stability.t ->
  os : Arch.os option ->
  machine : Arch.machine option ->
  version : Version.t ->
  'a -> 'a t

val with_stability : Stability.t -> 'a t -> 'a t

(** {2 Utility functions} *)

val make_command :
  ?source_hint:_ Element.t ->
  string -> Support.Common.filepath -> command

val make_distribtion_restriction : string -> restriction
val make_version_restriction : string -> restriction

val local_dir_of : [> `Local_impl of Support.Common.filepath ] t -> Support.Common.filepath option

(** [parse_dep local_dir elem] parses the <requires>/<restricts> element.
 * [local_dir] is used to resolve relative interface names in local feeds
 * (use [None] for remote feeds). *)
val parse_dep : Support.Common.filepath option -> [< Element.dependency_node] Element.t -> dependency

(** [parse_command local_dir elem] parses the <command> element.
 * [local_dir] is used to process dependencies (see [parse_dep]). *)
val parse_command : Support.Common.filepath option -> [`Command] Element.t -> command

val get_attr_ex : string -> _ t -> string

val is_source : _ t -> bool
val needs_compilation : [< impl_type ] t -> bool

(** [existing_source impl] returns impl if it already exists, or the source implementation
 * which can be used to build it if not. *)
val existing_source : [< impl_type ] t -> existing t

val get_command_opt : string -> _ t -> command option
val get_command_ex : string -> _ t -> command

val get_langs : _ t -> Support.Locale.lang_spec list
val is_retrievable_without_network : cache_impl -> bool
val get_id : _ t -> Feed_url.global_id

(** Formats the XML element and location, for debug logging with [%a]. *)
val fmt : Format.formatter -> _ t -> unit
