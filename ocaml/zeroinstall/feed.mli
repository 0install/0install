(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing feeds *)

(** {2 Types} **)

module AttrType : sig type t = Xmlm.name val compare : 'a -> 'a -> int end
module AttrMap : (Map.S with type key = AttrType.t)

(** A globally-unique identifier for an implementation. *)
type global_id = {
  feed : Feed_url.parsed_feed_url;
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
  feed_src : Feed_url.non_distro_feed;

  feed_os : string option;          (* All impls requires this OS *)
  feed_machine : string option;     (* All impls requires this CPU *)
  feed_langs : string list option;  (* No impls for languages not listed *)
  feed_type : feed_type;
}

type feed = {
  url : Feed_url.non_distro_feed;
  root : Support.Qdom.element;
  name : string;
  implementations : implementation Support.Common.StringMap.t;
  imported_feeds : feed_import list;    (* Always of type Feed_import here *)

  (* The URI of the interface that replaced the one with the URI of this feed's URL.
     This is the value of the feed's <replaced-by interface'...'/> element. *)
  replacement : General.iface_uri option;

  package_implementations : (Support.Qdom.element * properties) list;
}

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

val load_feed_overrides : General.config -> [< Feed_url.parsed_feed_url] -> feed_overrides
val save_feed_overrides : General.config -> [< Feed_url.parsed_feed_url] -> feed_overrides -> unit
val update_last_checked_time : General.config -> [< `remote_feed of General.feed_url] -> unit
val get_langs : implementation -> Support.Locale.lang_spec list
val is_available_locally : General.config -> implementation -> bool
val is_retrievable_without_network : cache_impl -> bool
val get_id : implementation -> global_id
val get_summary : int Support.Locale.LangMap.t -> feed -> string option
val get_description : int Support.Locale.LangMap.t -> feed -> string option

(** The <feed-for> elements' interfaces *)
val get_feed_targets : feed -> General.iface_uri list
val make_user_import : [<`local_feed of Support.Common.filepath | `remote_feed of General.feed_url] -> feed_import
