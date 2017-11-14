(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Manages the process of downloading feeds during a solve.
    We use the solver to get the current best solution and the set of feeds it queried.
    We download any missing feeds and update any out-of-date ones, resolving each time
    we have more information. *)

(** Find the best selections for these requirements and return them if available without downloading. 
 * Returns None if we need to refresh feeds or download any implementations. *)
val quick_solve :
  < config : General.config; distro : Distro.t; .. > ->
  Requirements.t -> Selections.t option

(** Run the solver, then download any feeds that are missing or that need to be
    updated. Each time a new feed is imported into the cache, the solver is run
    again, possibly adding new downloads.

    Note: if we find we need to download anything, we will refresh everything.

    @param watcher notify of each partial solve (used by the GUI to show the current state)
    @param force re-download all feeds, even if we're ready to run (implies update_local)
    @param update_local fetch PackageKit feeds even if we're ready to run
    
    @return whether a valid solution was found, the solution itself, and the feed
            provider used (which will have cached all the feeds used in the solve).
    *)
val solve_with_downloads :
  General.config -> Distro.t -> Fetch.fetcher ->
  watcher:#Progress.watcher ->
  Requirements.t ->
  force:bool ->
  update_local:bool ->
  (bool * Solver.Model.t * Feed_provider.feed_provider) Lwt.t

(** Convenience wrapper for [fetcher#download_and_import_feed] that just gives the final result.
 * If the mirror replies first, but the primary succeeds, we return the primary. *)
val download_and_import_feed :
  Fetch.fetcher ->
  Feed_url.remote_feed ->
  [ `Aborted_by_user | `No_update | `Success of [`Feed] Element.t ] Lwt.t

(** Download any missing implementations needed for a set of selections.
 * @param include_packages whether to include distribution packages
 * @param feed_provider it's more efficient to reuse the provider returned by [solve_with_downloads], if possible
 *)
val download_selections :
  General.config -> Distro.t ->
  Fetch.fetcher Lazy.t ->
  include_packages:bool ->
  feed_provider:Feed_provider.feed_provider ->
  Selections.t -> [ `Aborted_by_user | `Success ] Lwt.t

(** If [distro] is set then <package-implementation>s are included. Otherwise, they are ignored. *)
val get_unavailable_selections : General.config -> ?distro:Distro.t -> Selections.t -> Selections.selection list
