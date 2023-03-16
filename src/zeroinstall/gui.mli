(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Manage the GUI sub-process. *)

type feed_description = {
  times : (string * float) list;
  summary : string option;
  description : string list;
  homepages : string list;
  signatures : [
    | `Valid of Support.Gpg.fingerprint * Support.Gpg.timestamp * string option * [`Trusted | `Not_trusted]
    | `Invalid of string
  ] list;
}

(** The GUI plugin registers itself here. *)
val register_plugin : (General.config -> Ui.ui_handler option) -> unit

val download_icon : Fetch.fetcher -> Feed_provider.feed_provider -> Feed_url.non_distro_feed -> unit Lwt.t

(** Should we use the GUI?
 * The input says what the user requested:
 * No -> we never want to use the GUI
 * Yes -> we always want to use the GUI, and throw an exception if it's not available
 * Auto -> we want to use the GUI iff it's available
 *
 * Returns a suitable GUI handler if so, or None if we should use a non-GUI handler.
 *)
val try_get_gui : General.config -> use_gui:[< `Yes | `No | `Auto] -> Ui.ui_handler option

(** Download the feed and add it as an extra feed of the interface. *)
val add_remote_feed :
  General.config ->
  Fetch.fetcher ->
  Sigs.iface_uri -> Feed_url.remote_feed -> unit Lwt.t

(** Add a local feed to an interface. *)
val add_feed : General.config -> Sigs.iface_uri -> Feed_url.local_feed -> unit
val remove_feed : General.config -> Sigs.iface_uri -> Feed_url.non_distro_feed -> unit
val compile : General.config -> Feed_provider.feed_provider -> Sigs.iface_uri -> autocompile:bool -> unit Lwt.t

(** Try to guess whether we have source for this interface.
 * Returns true if we have any source-only feeds, or any source implementations
 * in our regular feeds. However, we don't look inside the source feeds (so a
 * source feed containing no implementations will still count as true).
 * This is used in the GUI to decide whether to shade the Compile button.
 *)
val have_source_for : Feed_provider.feed_provider -> Sigs.iface_uri -> bool

(** List the implementations of this interface in the order they should be shown in the GUI.
 * @return (selected_version, implementations). *)
val list_impls : Solver.Output.t -> Solver.role ->
  (Impl.generic_implementation option * (Impl.generic_implementation * Impl_provider.rejection_reason option) list)

(* Returns (fetch-size, fetch-tooltip) *)
val get_fetch_info : General.config -> Impl.generic_implementation -> (string * string)

val run_test : General.config -> Distro.t -> (Selections.t -> string Lwt.t) -> (bool * Solver.Output.t) -> string Lwt.t

val generate_feed_description : General.config -> Trust.trust_db -> Feed.t -> Feed_metadata.t -> feed_description Lwt.t
