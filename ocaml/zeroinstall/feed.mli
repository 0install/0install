(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing feeds *)

(** {2 Types} **)

module AttrType : sig type t = Xmlm.name val compare : 'a -> 'a -> int end
module AttrMap : (Map.S with type key = AttrType.t)

(** A globally-unique identifier for an implementation. *)
type global_id = {
  feed : General.feed_url;
  id : string;
}

type importance =
  | Dep_essential       (* Must select a version of the dependency *)
  | Dep_recommended     (* Prefer to select a version, if possible *)
  | Dep_restricts       (* Just adds restrictions without expressing any opinion *)

type package_impl = {
  package_distro : string;
  package_installed : bool;
  retrieval_method : (string * Yojson.Basic.json) list option;
}

type cache_impl = {
  digests : Stores.digest list;
  retrieval_methods : Support.Qdom.element list;
}

type impl_type =
  | CacheImpl of cache_impl
  | LocalImpl of Support.Common.filepath
  | PackageImpl of package_impl

type restriction = < meets_restriction : implementation -> bool; to_string : string >
and binding = Support.Qdom.element
and dependency = {
  dep_qdom : Support.Qdom.element;
  dep_importance : importance;
  dep_iface : General.iface_uri;
  dep_restrictions : restriction list;
  dep_required_commands : string list;
  dep_if_os : string option;                (* The badly-named 'os' attribute *)
  dep_use : string option;                  (* Deprecated 'use' attribute *)
}
and command = {
  command_qdom : Support.Qdom.element;
  command_requires : dependency list;
  (* command_bindings : binding list; - not needed by solver; just copies the element *)
}
and properties = {
  attrs : string AttrMap.t;
  requires : dependency list;
  bindings : binding list;
  commands : command Support.Common.StringMap.t;
}
and implementation = {
  qdom : Support.Qdom.element;
  props : properties;
  stability : General.stability_level;
  os : string option;           (* Required OS; the first part of the 'arch' attribute. None for '*' *)
  machine : string option;      (* Required CPU; the second part of the 'arch' attribute. None for '*' *)
  parsed_version : Versions.parsed_version;
  impl_type : impl_type;
}

type feed_overrides = {
  last_checked : float option;
  user_stability : General.stability_level Support.Common.StringMap.t;
}

type feed_type =
  | Feed_import             (* A <feed> import element inside a feed *)
  | User_registered         (* Added manually with "0install add-feed" : save to config *)
  | Site_packages           (* Found in the site-packages directory : save to config for older versions, but flag it *)
  | Distro_packages         (* Found in native_feeds : don't save *)

type feed_import = {
  feed_src : General.feed_url;

  feed_os : string option;          (* All impls requires this OS *)
  feed_machine : string option;     (* All impls requires this CPU *)
  feed_langs : string list option;  (* No impls for languages not listed *)
  feed_type : feed_type;
}

type feed = {
  url : General.feed_url;
  root : Support.Qdom.element;
  name : string;
  implementations : implementation Support.Common.StringMap.t;
  imported_feeds : feed_import list;

  (* The URI of the interface that replaced the one with the URI of this feed's URL.
     This is the value of the feed's <replaced-by interface'...'/> element. *)
  replacement : General.iface_uri option;

  package_implementations : (Support.Qdom.element * properties) list;
}

(** {2 Constants} *)

(** Some constant strings used in the XML (to avoid typos) *)

val elem_group : string
val elem_implementation : string
val elem_package_implementation : string

val attr_id : string
val attr_command : string
val attr_main : string
val attr_self_test : string
val attr_stability : string
val attr_user_stability : string
val attr_importance : string
val attr_version : string
val attr_released : string
val attr_os : string
val attr_use : string
val attr_local_path : string
val attr_lang : string
val attr_langs : string
val attr_interface : string
val attr_src : string
val attr_from_feed : string
val attr_if_0install_version : string
val attr_distribution : string
val value_testing : string

(** {2 Parsing} *)
val parse : Support.Common.system -> Support.Qdom.element -> Support.Common.filepath option -> feed

(** {2 Utility functions} *)
val parse_stability : from_user:bool -> string -> General.stability_level
val format_stability : General.stability_level -> string

val make_command :
  Support.Qdom.document ->
  ?source_hint:Support.Qdom.element ->
  string -> ?new_attr:string -> Support.Common.filepath -> command

val make_distribtion_restriction : string -> restriction
val make_version_restriction : string -> restriction

val get_attr_opt : string -> string AttrMap.t -> string option
val get_attr_ex : string -> implementation -> string

val get_implementations : feed -> implementation list
val is_source : implementation -> bool

val get_command_opt : string -> command Support.Common.StringMap.t -> command option
val get_command_ex : implementation -> string -> command

val load_feed_overrides : General.config -> General.feed_url -> feed_overrides
val update_last_checked_time : General.config -> General.feed_url -> unit
val get_distro_feed : feed -> General.feed_url option
val get_langs : implementation -> Support.Locale.lang_spec list
val is_available_locally : General.config -> implementation -> bool
val is_retrievable_without_network : cache_impl -> bool
val get_id : implementation -> global_id
val get_summary : int Support.Locale.LangMap.t -> feed -> string option
