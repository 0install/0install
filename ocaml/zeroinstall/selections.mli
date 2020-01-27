(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Handling selections XML documents.
 * See: http://0install.net/selections-spec.html *)

open Support.Common

(** {2 Types} *)

type selection = [`Selection] Element.t
type role = {
  iface : Sigs.iface_uri;
  source : bool;
}

include Sigs.SELECTIONS with
  type impl = selection and
  type command_name = string and
  type Role.t = role

type impl_source =
  | CacheSelection of Manifest.digest list
  | LocalSelection of string
  | PackageSelection


(** {2 Selections documents} *)

(** Load a selections document. *)
val create : Support.Qdom.element -> t

(** Create a [selections] value from a file (parse + create). *)
val load_selections : #filesystem -> filepath -> t

(** The role of the root selection. *)
val root_role : t -> role

(** The command on [root_role] to run. *)
val root_command : t -> string option

(** The selection for [root_role]. *)
val root_sel : t -> selection

(** Iterate over the <selection> elements. *)
val iter : (role -> selection -> unit) -> t -> unit

(** Check whether the XML of two sets of selections are the same, ignoring whitespace. *)
val equal : t -> t -> bool

(** Like [get_selected], but raise an exception if not found. *)
val get_selected_ex : role -> t -> selection

(** Convert a selections document to XML in the latest format. *)
val as_xml : t -> Support.Qdom.element

(** Return all bindings *)
val collect_bindings : t -> (role * Element.binding) list

(** {2 Selection elements} *)

val get_source : selection -> impl_source

(** Look up this selection's directory.
 * @return None for package implementations. *)
val get_path : #filesystem -> Stores.stores -> selection -> filepath option

(** Get the URL of the feed this selection came from. *)
val get_feed : selection -> Sigs.feed_url

(** Get the globally unique ID of this selection (feed + ID) *)
val get_id : selection -> Feed_url.global_id
