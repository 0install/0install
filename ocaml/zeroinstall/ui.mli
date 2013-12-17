(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Common types for user interface callbacks *)

class type ui_handler =
  object
    (** Choose (and possibly download) a set of implementations.
     * @param test_callback is used if the user clicks on the test button in the bug report dialog.
     * @param systray is used during background updates - just show an icon in the systray if possible
     *)
    method run_solver :
      < config : General.config; distro : Distro.distribution; make_fetcher : Progress.watcher -> Fetch.fetcher; .. > ->
      ?test_callback:(Support.Qdom.element -> string Lwt.t) ->
      ?systray:bool ->
      [`Download_only | `Select_for_run | `Select_only] ->
      Requirements.requirements ->
      refresh:bool ->
      [`Aborted_by_user | `Success of Support.Qdom.element ] Lwt.t
    
    (** Display the Preferences dialog. Resolves when dialog is closed.
     * @return None if we don't have a GUI available. *)
    method show_preferences : unit Lwt.t option

    method open_app_list_box : unit Lwt.t

    method open_add_box : General.feed_url -> unit Lwt.t

    method open_cache_explorer : unit Lwt.t

    method watcher : Progress.watcher
  end
