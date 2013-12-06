(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Manage the GUI sub-process. *)

class type gui_ui =
  object
    inherit Ui.ui_handler
    inherit Python.slave
    
    (** Display the Preferences dialog. Resolves when dialog is closed. *)
    method show_preferences : unit Lwt.t

    (** Display the Component Properties dialog for this interface. *)
    method show_component : driver:Driver.driver -> General.iface_uri -> select_versions_tab:bool -> unit

    (** Forwarded from [Driver.watcher#update] as the solve makes progress. 
     * Once the main window is migrated, we can clean up this API. *)
    method update : Requirements.requirements -> ((bool * Solver.result) * Feed_provider.feed_provider) -> unit

    (** Display an error to the user. *)
    method report_error : exn -> unit
  end

type ui_type =
  | Gui of gui_ui
  | Ui of Ui.ui_handler

(** The GUI plugin registers itself here. *)
val register_plugin : (General.config -> Support.Common.yes_no_maybe -> gui_ui option) -> unit

val get_selections_gui :
  gui_ui ->
  Driver.driver ->
  ?test_callback:(Support.Qdom.element -> string Lwt.t) ->
  ?systray:bool ->
  [< `Download_only | `Select_for_run | `Select_only ] ->
  Requirements.requirements ->
  refresh:bool ->
  [> `Aborted_by_user | `Success of Support.Qdom.element ] Lwt.t

val download_icon : General.config -> Downloader.downloader -> Feed_provider.feed_provider -> Feed_url.non_distro_feed -> unit Lwt.t

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
val add_remote_feed : Driver.driver -> General.iface_uri -> [`remote_feed of General.feed_url] -> unit Lwt.t
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
