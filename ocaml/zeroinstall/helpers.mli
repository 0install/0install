(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** High-level helper functions *)

type select_mode = [
  | `Select_only       (* only download feeds, not archives; display "Select" in GUI *)
  | `Download_only     (* download archives too; refresh if stale feeds; display "Download" in GUI *)
  | `Select_for_run    (* download archives; update stale in background; display "Run" in GUI *)
]

(** Ensure all selections are cached, downloading any that are missing. *)
val download_selections :
  include_packages:bool ->
  feed_provider:Feed_provider.feed_provider ->
  Ui.ui_handler Fetch.fetcher ->
  Support.Qdom.element ->
  unit Lwt.t

(** Get some selectsions for these requirements.
    Returns [None] if the user cancels.
    @raise Safe_exception if the solve fails. *)
val solve_and_download_impls :
  Gui.ui_type ->
  Ui.ui_handler Fetch.fetcher ->
  ?test_callback:(Support.Qdom.element -> string Lwt.t) ->
  Requirements.requirements ->
  select_mode ->
  refresh:bool ->
  Support.Qdom.element option Lwt.t

(** Create a UI appropriate for the current environment and user options.
 * This will be a graphical UI if [Gui.try_get_gui] returns one and we're not in dry-run mode.
 * Otherwise, it will be an interactive console UI if stderr is a tty.
 * Otherwise, it will be a batch UI (no progress display).
 *)
val make_ui :
  General.config ->
  Support.Common.yes_no_maybe ->
  Gui.ui_type
