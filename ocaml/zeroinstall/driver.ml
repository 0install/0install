(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
open Support.Common

module U = Support.Utils
let (>|=) = Lwt.(>|=)

(** Manages the process of downloading feeds during a solve.
    We use the solver to get the current best solution and the set of feeds it queried.
    We download any missing feeds and update any out-of-date ones, resolving each time
    we have more information. *)

let get_values map = StringMap.fold (fun _key value xs -> value :: xs) map []

(** Run the solver, then download any feeds that are missing or that need to be
    updated. Each time a new feed is imported into the cache, the solver is run
    again, possibly adding new downloads.

    Note: if we find we need to download anything, we will refresh everything.

    @param force re-download all feeds, even if we're ready to run (implies update_local)
    @param watcher notify of each partial solve (used by the GUI to show the current state)
    @param update_local fetch PackageKit feeds even if we're ready to run *)
let solve_with_downloads config fetcher distro ?feed_provider ?watcher requirements ~force ~update_local : (bool * Solver.result) =
  let force = ref force in
  let seen = ref StringSet.empty in
  let downloads_in_progress = ref StringMap.empty in

  let already_seen url = StringSet.mem url !seen in
  let forget_feed url = seen := StringSet.remove url !seen in

  (* There are three cases:
     1. We want to run immediately if possible. If not, download all the information we can.
        (force = False, update_local = False)
     2. We're in no hurry, but don't want to use the network unnecessarily.
        We should still update local information (from PackageKit).
        (force = False, update_local = True)
     3. The user explicitly asked us to refresh everything.
        (force = True) *)

  let feed_provider =
    match feed_provider with
    | Some feed_provider -> feed_provider
    | None -> new Feed_cache.feed_provider config distro in

  (* Add [url] to [downloads_in_progress]. When [download] resolves (to a function),
     call it in the main thread. *)
  let add_download url download =
    seen := StringSet.add url !seen;
    log_info "Waiting for download of feed '%s'" url;
    let wrapped =
      try_lwt
        lwt fn = download in
        log_info "Download of feed '%s' finished" url;
        Lwt.return (url, fn)
      with ex ->
        let () =
          match watcher with
          | Some watcher -> watcher#report ex
          | None -> log_warning ~ex "Feed download %s failed" url in
        Lwt.return (url, fun () -> ()) in
    downloads_in_progress := StringMap.add url wrapped !downloads_in_progress
    in

  let rec loop ~try_quick_exit =
    (* Called once at the start, and once for every feed that downloads (or fails to download). *)
    let result = Solver.solve_for config feed_provider requirements in

    let () =
      match watcher with
      | Some watcher -> watcher#update result
      | None -> () in

    match result with
    | (true, _) when try_quick_exit ->
        assert (StringMap.is_empty !downloads_in_progress);
        result
    | (ready, _) ->
        if not ready then force := true;

        (* For each remote feed used which we haven't seen yet, start downloading it. *)
        if !force && config.network_use <> Offline then (
          ListLabels.iter feed_provider#get_feeds_used ~f:(fun f ->
            if not (already_seen f) && not (Feed_cache.is_local_feed f) then (
              add_download f (fetcher#download_and_import_feed f >|= fun download () ->
                match download with
                | `aborted_by_user -> ()    (* No need to report this *)
                | `success ->
                    feed_provider#forget f;
                    (* On success, we also need to refetch any "distribution" feed that depends on this one *)
                    let distro_url = "distribution:" ^ f in
                    feed_provider#forget distro_url;
                    forget_feed distro_url;
                    (* (we will now refresh, which will trigger distro#check_for_candidates *)
              )
            )
          )
        );

        (* Check for extra (uninstalled) local distro candidates. *)
        if !force || update_local then (
          ListLabels.iter feed_provider#get_feeds_used ~f:(fun f ->
            match feed_provider#get_feed f with
            | None -> ()
            | Some (master_feed, _) ->
                let f = "distribution:" ^ f in
                if not (already_seen f) then (
                    add_download f (distro#check_for_candidates master_feed >|= fun () () ->
                      feed_provider#forget_distro f
                    )
                )
          )
        );

        match get_values !downloads_in_progress with
        | [] -> 
            if config.network_use = Offline && not ready then
              log_info "Can't choose versions and in off-line mode, so aborting";
            result;
        | downloads ->
            let (url, fn) = Lwt_main.run @@ Lwt.choose downloads in
            downloads_in_progress := StringMap.remove url !downloads_in_progress;
            fn ();    (* Clears the old feed(s) from Feed_cache *)
            (* Run the solve again with the new information. *)
            loop ~try_quick_exit:false
  in
  loop ~try_quick_exit:(not (!force || update_local))
