(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Manage the GUI sub-process. *)

(** The GUI plugin registers itself here. *)
val register_plugin : (General.config -> Support.Common.yes_no_maybe -> Ui.ui_handler option) -> unit

val get_selections_gui :
  Ui.gui_ui ->
  Driver.driver ->
  ?test_callback:(Support.Qdom.element -> string Lwt.t) ->
  ?systray:bool ->
  [< `Download_only | `Select_for_run | `Select_only ] ->
  Requirements.requirements ->
  refresh:bool ->
  [> `Aborted_by_user | `Success of Support.Qdom.element ] Lwt.t

val download_icon : General.config -> Downloader.downloader -> Feed_provider.feed_provider -> Feed_url.non_distro_feed -> unit Lwt.t

val register_preferences_handlers : General.config -> unit

(** Should we use the GUI?
 * The input says what the user requested:
 * No -> we never want to use the GUI
 * Yes -> we always want to use the GUI, and throw an exception if it's not available
 * Maybe -> we want to use the GUI iff it's available
 *
 * Returns a suitable GUI handler if so, or None if we should use a non-GUI handler.
 *)
val try_get_gui : General.config -> use_gui:Support.Common.yes_no_maybe -> Ui.ui_handler option
