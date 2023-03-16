(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Common types for user interface callbacks *)

type select_mode = [
  | `Select_only       (* only download feeds, not archives; display "Select" in GUI *)
  | `Download_only     (* download archives too; refresh if stale feeds; display "Download" in GUI *)
  | `Select_for_run    (* download archives; update stale in background; display "Run" in GUI *)
]

class type ui_handler =
  object
    (** Choose (and possibly download) a set of implementations.
     * @param systray is used during background updates - just show an icon in the systray if possible
     *)
    method run_solver :
      < config : General.config; distro : Distro.t; make_fetcher : Progress.watcher -> Fetch.fetcher; .. > ->
      ?systray:bool ->
      select_mode ->
      Requirements.t ->
      refresh:bool ->
      [`Aborted_by_user | `Success of Selections.t] Lwt.t
    
    (** Display the Preferences dialog. Resolves when dialog is closed.
     * @return None if we don't have a GUI available. *)
    method show_preferences : unit Lwt.t option

    method open_app_list_box : unit Lwt.t

    method open_add_box : Sigs.feed_url -> unit Lwt.t

    method open_cache_explorer : unit Lwt.t

    method watcher : Progress.watcher
  end
