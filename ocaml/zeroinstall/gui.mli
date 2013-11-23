(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Manage the GUI sub-process. *)

val get_selections_gui :
  Python.slave ->
  Driver.driver ->
  ?test_callback:(Support.Qdom.element -> string Lwt.t) ->
  ?systray:bool ->
  [< `Download_only | `Select_for_run | `Select_only ] ->
  Requirements.requirements ->
  refresh:bool ->
  [> `Aborted_by_user | `Success of Support.Qdom.element ] Lwt.t

val download_icon : General.config -> Downloader.downloader -> Feed_provider.feed_provider -> Feed_url.non_distro_feed -> unit Lwt.t

val register_preferences_handlers : General.config -> unit
