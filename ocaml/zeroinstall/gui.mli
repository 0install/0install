(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Manage the GUI sub-process. *)

class type gui_ui =
  object
    inherit Ui.ui_handler

    (** Run the GUI to choose and download a set of implementations
     * [test_callback] is used if the user clicks on the test button in the bug report dialog.
     *)
    method run_solver :
      Distro.distribution -> Downloader.downloader ->
      ?test_callback:(Support.Qdom.element -> string Lwt.t) ->
      ?systray:bool ->
      [`Download_only | `Select_for_run | `Select_only] ->
      Requirements.requirements ->
      refresh:bool ->
      [`Aborted_by_user | `Success of Support.Qdom.element ] Lwt.t
    
    (** Display the Preferences dialog. Resolves when dialog is closed. *)
    method show_preferences : unit Lwt.t

    method open_app_list_box : unit Lwt.t

    method open_add_box : General.feed_url -> unit Lwt.t

    method open_cache_explorer : unit Lwt.t
  end

type ui_type =
  | Gui of gui_ui
  | Ui of Ui.ui_handler

(** The GUI plugin registers itself here. *)
val register_plugin : (General.config -> Support.Common.yes_no_maybe -> gui_ui option) -> unit

val download_icon : General.config -> Downloader.downloader -> Ui.ui_handler -> Feed_provider.feed_provider -> Feed_url.non_distro_feed -> unit Lwt.t

(** Should we use the GUI?
 * The input says what the user requested:
 * No -> we never want to use the GUI
 * Yes -> we always want to use the GUI, and throw an exception if it's not available
 * Maybe -> we want to use the GUI iff it's available
 *
 * Returns a suitable GUI handler if so, or None if we should use a non-GUI handler.
 *)
val try_get_gui : General.config -> use_gui:Support.Common.yes_no_maybe -> gui_ui option

(** Download the feed and add it as an extra feed of the interface. *)
val add_remote_feed : Ui.ui_handler Fetch.fetcher -> General.iface_uri -> [`remote_feed of General.feed_url] -> unit Lwt.t
(** Add a local feed to an interface. *)
val add_feed : General.config -> General.iface_uri -> [`local_feed of Support.Common.filepath] -> unit
val remove_feed : General.config -> General.iface_uri -> Feed_url.non_distro_feed -> unit
val compile : General.config -> Feed_provider.feed_provider -> General.iface_uri -> autocompile:bool -> unit Lwt.t

(** Try to guess whether we have source for this interface.
 * Returns true if we have any source-only feeds, or any source implementations
 * in our regular feeds. However, we don't look inside the source feeds (so a
 * source feed containing no implementations will still count as true).
 * This is used in the GUI to decide whether to shade the Compile button.
 *)
val have_source_for : Feed_provider.feed_provider -> General.iface_uri -> bool

(** List the implementations of this interface in the order they should be shown in the GUI.
 * @return (selected_version, implementations), or None if this interface wasn't used in the solve. *)
val list_impls : Solver.result -> General.iface_uri ->
  (Feed.implementation option * (Feed.implementation * Impl_provider.rejection option) list) option

(* Returns (fetch-size, fetch-tooltip) *)
val get_fetch_info : General.config -> Feed.implementation -> (string * string)

(** Set a user-override stability rating. *)
val set_impl_stability : General.config -> Feed.global_id -> General.stability_level option -> unit

(** Get the initial text for the bug report dialog box. *)
val get_bug_report_details : General.config -> iface:General.iface_uri -> (bool * Solver.result) -> string

(** Submit a bug report for this interface.
 * @return the response from the server (on success).
 * @raise Safe_exception on failure. *)
val send_bug_report : General.iface_uri -> string -> string Lwt.t

(** Find the [Feed.implementation] which produced this selection. If there is an override on the stability, return that too. *)
val get_impl : Feed_provider.feed_provider -> Support.Qdom.element -> (Feed.implementation * General.stability_level option) option

val run_test : General.config -> Distro.distribution -> (Support.Qdom.element -> string Lwt.t) -> (bool * Solver.result) -> string Lwt.t
