(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
open Support.Common

let (>|=) = Lwt.(>|=)

exception Aborted_by_user

(* Turn a list of tasks into a list of their resolutions.
 * If any failed, we throw the first one's exception. *)
let rec collect_ex = function
  | [] -> Lwt.return []
  | x :: xs ->
      x >>= fun result ->
      collect_ex xs >|= fun results ->
      result :: results
   
(** If [distro] is set then <package-implementation>s are included. Otherwise, they are ignored. *)
let get_unavailable_selections config ?distro sels =
  let missing = ref [] in

  let needs_download elem =
    match Selections.get_source elem with
    | Selections.LocalSelection _ -> false
    | Selections.CacheSelection digests -> None = Stores.lookup_maybe config.system digests config.stores
    | Selections.PackageSelection ->
        match distro with
        | None -> false
        | Some distro -> not @@ Distro.is_installed distro elem
  in
  sels |> Selections.iter (fun role sel ->
    if needs_download sel then (
      Element.log_elem Support.Logging.Info "Missing selection of %s:" (Selections.Role.to_string role) sel;
      missing := sel :: !missing
    )
  );
  !missing

(** Find a package implementation. Note: does not call [distro#check_for_candidates]. *)
let find_distro_impl feed_provider id master_feed =
  let result = feed_provider#get_distro_impls master_feed in
  StringMap.find_nf id result.Feed_provider.impls

(** Find a cached implementation. Not_found if the feed isn't cached or doesn't contain [id]. *)
let find_zi_impl feed_provider id url =
  let (feed, _) = feed_provider#get_feed url |? lazy (raise Not_found) in
  StringMap.find_nf id feed.Feed.implementations

module DownloadElt =
  struct
    type t = Feed_url.parsed_feed_url
    let compare = compare
  end

module DownloadSet = Set.Make(DownloadElt)
module DownloadMap = Map.Make(DownloadElt)

let get_values map = DownloadMap.fold (fun _key value xs -> value :: xs) map []

let solve_with_downloads config distro fetcher ~(watcher:#Progress.watcher) requirements ~force ~update_local =
  let force = ref force in
  let seen = ref DownloadSet.empty in
  let downloads_in_progress = ref DownloadMap.empty in

  let already_seen url = DownloadSet.mem (url :> Feed_url.parsed_feed_url) !seen in
  let forget_feed url = seen := DownloadSet.remove url !seen in

  (* There are three cases:
     1. We want to run immediately if possible. If not, download all the information we can.
        (force = False, update_local = False)
     2. We're in no hurry, but don't want to use the network unnecessarily.
        We should still update local information (from PackageKit).
        (force = False, update_local = True)
     3. The user explicitly asked us to refresh everything.
        (force = True) *)

  let feed_provider = new Feed_provider_impl.feed_provider config distro in

  (* Add [url] to [downloads_in_progress]. When [download] resolves (to a function),
     call it in the main thread. *)
  let add_download url download =
    let url = (url :> Feed_url.parsed_feed_url) in
    seen := DownloadSet.add url !seen;
    let wrapped =
      Lwt.catch
        (fun () -> download >|= fun fn -> (url, fn))
        (function
          | Safe_exception (msg, _) ->
            watcher#report url msg;
            Lwt.return (url, fun () -> ())
          | ex -> Lwt.fail ex (* or report this too? *)
        ) in
    downloads_in_progress := DownloadMap.add url wrapped !downloads_in_progress
    in

  (* Register a new download. When it resolves, process it in the main thread. *)
  let rec handle_download f dl =
    add_download f (dl >|= fun result () ->
      (* (we are now running in the main thread) *)
      match result with
      | `Problem (msg, next_update) -> (
          watcher#report f msg;
          match next_update with
          | None -> ()
          | Some next -> handle_download f next
      )
      | `Aborted_by_user -> ()    (* No need to report this *)
      | `No_update -> ()
      | `Update (new_xml, next_update) ->
          feed_provider#replace_feed f (Feed.parse config.system new_xml None);
          (* On success, we also need to refetch any "distribution" feed that depends on this one *)
          feed_provider#forget_distro f;
          forget_feed (`Distribution_feed f);
          (* (we will now refresh, which will trigger distro#check_for_candidates *)
          match next_update with
          | None -> ()    (* This is the final update *)
          | Some next ->
              log_info "Accepted update from mirror, but will continue waiting for primary for '%s'" (Feed_url.format_url f);
              handle_download f next
    ) in

  let rec loop ~try_quick_exit =
    (* Called once at the start, and once for every feed that downloads (or fails to download). *)
    let result = Solver.solve_for config feed_provider requirements in

    watcher#update (result, feed_provider);

    match result with
    | (true, _) when try_quick_exit ->
        assert (DownloadMap.is_empty !downloads_in_progress);
        Lwt.return result
    | (ready, _) ->
        if not ready then force := true;

        (* For each remote feed used which we haven't seen yet, start downloading it. *)
        if !force && config.network_use <> Offline then (
          ListLabels.iter feed_provider#get_feeds_used ~f:(fun f ->
            if not (already_seen f) then (
              match f with
              | `Local_feed _ -> ()
              | `Remote_feed _ as feed ->
                  log_info "Starting download of feed '%s'" (Feed_url.format_url f);
                  fetcher#download_and_import_feed feed |> handle_download f
            )
          )
        );

        (* Check for extra (uninstalled) local distro candidates. *)
        if !force || update_local then (
          ListLabels.iter feed_provider#get_feeds_used ~f:(fun f ->
            match feed_provider#get_feed f with
            | None -> ()
            | Some (master_feed, _) ->
                let distro_f = `Distribution_feed f in
                if not (already_seen distro_f) then (
                    add_download distro_f (Distro.check_for_candidates distro ~ui:watcher master_feed >|= fun () () ->
                      feed_provider#forget_distro f
                    )
                )
          )
        );

        match get_values !downloads_in_progress with
        | [] -> 
            if config.network_use = Offline && not ready then
              log_info "Can't choose versions and in off-line mode, so aborting";
            Lwt.return result;
        | downloads ->
            Lwt.choose downloads >>= fun (url, fn) ->
            downloads_in_progress := DownloadMap.remove url !downloads_in_progress;
            fn ();    (* Clears the old feed(s) from Feed_cache *)
            (* Run the solve again with the new information. *)
            loop ~try_quick_exit:false
  in
  loop ~try_quick_exit:(not (!force || update_local)) >|= fun (ready, result) ->
  (ready, result, feed_provider)

let quick_solve tools reqs =
  let config = tools#config in
  let distro = tools#distro in
  let feed_provider = new Feed_provider_impl.feed_provider config distro in
  match Solver.solve_for config feed_provider reqs with
  | (true, results) ->
      let sels = Solver.selections results in
      if get_unavailable_selections config ~distro sels = [] then
        Some sels   (* A set of valid selections, available locally *)
      else
        None        (* Need to download to get the new selections *)
  | (false, _) ->
      None          (* Need to refresh before we can solve *)

let download_and_import_feed fetcher url =
  let `Remote_feed feed_url = url in
  let update = ref None in
  let rec wait_for (result:Fetch.fetch_feed_response Lwt.t) =
    result >>= function
    | `Update (feed, None) -> `Success feed |> Lwt.return
    | `Update (feed, Some next) ->
        update := Some feed;
        wait_for next
    | `Aborted_by_user -> Lwt.return `Aborted_by_user
    | `No_update -> (
        match !update with
        | None -> Lwt.return `No_update
        | Some update -> Lwt.return (`Success update)  (* Use the previous partial update *)
    )
    | `Problem (msg, None) -> (
        match !update with
        | None -> raise_safe "%s" msg
        | Some update ->
            (* Primary failed but we got an update from the mirror *)
            log_warning "Feed %s: %s" feed_url msg;
            Lwt.return (`Success update)  (* Use the previous partial update *)
    )
    | `Problem (msg, Some next) ->
        (* Problem with mirror, but primary might still succeeed *)
        log_warning "Feed '%s': %s" feed_url msg;
        wait_for next in

  wait_for @@ fetcher#download_and_import_feed url

(** Ensure all selections are cached, downloading any that are missing.
    If [include_packages] is given then distribution packages are also installed, otherwise
    they are ignored. *)
let download_selections config distro fetcher ~include_packages ~(feed_provider:Feed_provider.feed_provider) sels : [ `Success | `Aborted_by_user ] Lwt.t =
  let missing =
    let maybe_distro = if include_packages then Some distro else None in
    get_unavailable_selections config ?distro:maybe_distro sels in
  if missing = [] then (
    Lwt.return `Success
  ) else if config.network_use = Offline then (
    let format_sel sel =
      Element.interface sel ^ " " ^ Element.version sel in
    let items = missing |> List.map format_sel |> String.concat ", " in
    raise_safe "Can't download as in offline mode:\n%s" items
  ) else (
    (* We're missing some. For each one, get the feed it came from
     * and find the corresponding <implementation> in that. This will
     * tell us where to get it from.
     * Note: we look for an implementation with the same ID. Maybe we
     * should check it has the same digest(s) too?
     *)

    let fetcher = Lazy.force fetcher in

    (* Return the latest version of this feed, refreshing if possible. *)
    let get_latest_feed = function
      | `Local_feed path as parsed_feed_url ->
        let (feed, _) = feed_provider#get_feed parsed_feed_url |? lazy (raise_safe "Missing local feed '%s'" path) in
        Lwt.return feed
      | `Remote_feed feed_url as parsed_feed_url ->
          download_and_import_feed fetcher parsed_feed_url >>= function
          | `Aborted_by_user -> raise Aborted_by_user
          | `No_update ->
              let (feed, _) = feed_provider#get_feed parsed_feed_url |? lazy (raise_safe "Missing feed '%s'" feed_url) in
              Lwt.return feed
          | `Success new_root ->
              let feed = Feed.parse config.system new_root None in
              feed_provider#replace_feed parsed_feed_url feed;
              Lwt.return feed in

    (* Find the <implementation> corresponding to sel in the feed cache. If missing, download the feed and retry. *)
    let impl_of_sel sel =
      let {Feed_url.id; Feed_url.feed = feed_url} = Selections.get_id sel in

      let get_impl () =
        match feed_url with
        | `Remote_feed _ | `Local_feed _ as feed_url ->
            find_zi_impl feed_provider id feed_url
        | `Distribution_feed master_url ->
            match feed_provider#get_feed master_url with
            | None -> raise Not_found
            | Some (master_feed, _) -> (find_distro_impl feed_provider id master_feed :> Impl.existing Impl.t) in

      let refresh_feeds () =
        match feed_url with
        | `Local_feed _ -> Lwt.return ()
        | `Distribution_feed master_feed_url ->
            get_latest_feed master_feed_url >>= Distro.check_for_candidates distro ~ui:fetcher#ui
        | `Remote_feed _ as feed_url ->
            get_latest_feed feed_url >|= ignore in

      try
        get_impl () |> Lwt.return
      with Not_found ->
        (* Implementation is missing. Refresh everything and try again. *)
        refresh_feeds () >|= fun () ->
        try
          get_impl ()
        with Not_found ->
          raise_safe "Implementation '%s' not found in feed '%s'" id (Feed_url.format_url feed_url) in

    Lwt.catch
      (fun () -> missing |> List.map impl_of_sel |> collect_ex >>= fetcher#download_impls)
      (function
        | Aborted_by_user -> Lwt.return `Aborted_by_user
        | ex -> Lwt.fail ex
      )
  )

