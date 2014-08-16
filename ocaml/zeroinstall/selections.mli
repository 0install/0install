(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Handling selections XML documents.
 * See: http://0install.net/selections-spec.html *)

open Support.Common

(** {2 Types} *)

type t
type selection = Support.Qdom.element

type impl_source =
  | CacheSelection of Manifest.digest list
  | LocalSelection of string
  | PackageSelection


(** {2 Selections documents} *)

(** Load a selections document. *)
val create : Support.Qdom.element -> t

(** Create a [selections] value from a file (parse + create). *)
val load_selections : system -> filepath -> t

(** Create a map from interface URI to the corresponding selection. *)
val make_selection_map : t -> selection StringMap.t

(** The interface attribute on the root (i.e. the interface of the program itself) *)
val root_iface : t -> General.iface_uri

(** The command on [root_iface] to run. *)
val root_command : t -> string option

(** The selection for [root_iface]. *)
val root_sel : t -> selection

(** Iterate over the <selection> elements. *)
val iter : (selection -> unit) -> t -> unit

(** Check whether the XML of two sets of selections are the same, ignoring whitespace. *)
val equal : t -> t -> bool

(** Find the selection for a given interface.
 * This is slow; use [make_selection_map] for multiple lookups. *)
val find : General.iface_uri -> t -> selection option

(** Convert a selections document to XML in the latest format.
 * Note: this may be the exact XML passed to [create] if it was
 * already in the right format. *)
val as_xml : t -> Support.Qdom.element


(** {2 Selection elements} *)

val get_source : selection -> impl_source

(** Look up this selection's directory.
 * @return None for package implementations. *)
val get_path : system -> Stores.stores -> selection -> filepath option

(** Get the URL of the feed this selection came from. *)
val get_feed : selection -> General.feed_url

(** Get the globally unique ID of this selection (feed + ID) *)
val get_id : selection -> Feed_url.global_id

(** Get the direct dependencies (excluding any inside commands) of this <selection> or <command>.
 * @param restricts include <restricts> elements too *)
val get_dependencies : restricts:bool -> Support.Qdom.element -> Support.Qdom.element list

(** Find the <runner> child of this element (selection or command), if any.
 * @raise Safe_exception if there are multiple runners. *)
val get_runner : Support.Qdom.element -> Support.Qdom.element option

(** Return whether any implementation has mode="requires_compilation" *)
val requires_compilation : t -> bool
