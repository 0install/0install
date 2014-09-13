(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Handling selections XML documents.
 * See: http://0install.net/selections-spec.html *)

open Support.Common

(** {2 Types} *)

type t
type selection = [`selection] Element.t

type impl_source =
  | CacheSelection of Manifest.digest list
  | LocalSelection of string
  | PackageSelection


(** {2 Selections documents} *)

(** Load a selections document. *)
val create : Support.Qdom.element -> t

(** Create a [selections] value from a file (parse + create). *)
val load_selections : system -> filepath -> t

(** The interface attribute on the root (i.e. the interface of the program itself) *)
val root_iface : t -> General.iface_uri

(** The command on [root_iface] to run. *)
val root_command : t -> string option

(** The selection for [root_iface]. *)
val root_sel : t -> selection

(** Iterate over the <selection> elements. *)
val iter : (General.iface_uri -> selection -> unit) -> t -> unit

(** Check whether the XML of two sets of selections are the same, ignoring whitespace. *)
val equal : t -> t -> bool

(** Find the selection for a given interface. *)
val find : General.iface_uri -> t -> selection option

(** Like [find], but raise an exception if not found. *)
val find_ex : General.iface_uri -> t -> selection

(** Convert a selections document to XML in the latest format. *)
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

(* Return all bindings in document order *)
val collect_bindings : t -> (General.iface_uri * Element.binding) list
