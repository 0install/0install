(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
open Support.Common

module U = Support.Utils
module Q = Support.Qdom
module G = Support.Gpg
module FeedAttr = Constants.FeedAttr

type non_mirror_case = [ `ok of Q.element | `no_trusted_keys | `replay_attack of (feed_url * float * float) | `aborted_by_user ]

type fetch_feed_response =
  [ `update of (Q.element * fetch_feed_response Lwt.t option)  (* Use this version (but a better version may come soon) *)
  | `aborted_by_user        (* Abort silently (no need to notify the user) *)
  | `problem of (string * fetch_feed_response Lwt.t option)    (* Report a problem (but may still succeed later) *)
  | `no_update ]            (* Use the previous version *)

let re_scheme_sep = Str.regexp_string "://"

let string_of_result = function
  | `aborted_by_user -> "Aborted by user"
  | `no_trusted_keys -> "Not signed with a trusted key"
  | `replay_attack (url, old_time, new_time) ->
      let old_time = old_time |> Unix.localtime |> U.format_time in
      let new_time = new_time |> Unix.localtime |> U.format_time in
      Printf.sprintf (
        "New feed's modification time is before old version!\n" ^^
        "Interface: %s\nOld time: %s\nNew time: %s\n" ^^
        "Refusing update.") url old_time new_time

(** Convert the status from the primary to our public return value. *)
let get_final_response = function
  | `ok result -> `update (result, None)
  | `aborted_by_user -> `aborted_by_user
  | `no_trusted_keys as r -> `problem (string_of_result r, None)
  | `replay_attack _ as r ->
      (* Don't bother trying the mirror if we have a replay attack *)
      `problem (string_of_result r, None)

let last_ticket = ref 0
let timeout_tickets = ref StringMap.empty
let take_ticket timeout =
  last_ticket := !last_ticket + 1;
  let ticket = string_of_int !last_ticket in
  timeout_tickets := StringMap.add ticket timeout !timeout_tickets;
  ticket

let re_remote_feed = Str.regexp "^\\(https?\\)://\\([^/]*@\\)?\\([^/:]+\\)\\(:[^/]*\\)?/"

(** Wait for a set of tasks to complete. Return the exceptions produced by each, if any. *)
let rec join_errors = function
  | [] -> Lwt.return []
  | x :: xs ->
      try_lwt lwt () = x in join_errors xs
      with ex ->
        lwt exs = join_errors xs in
        ex :: exs |> Lwt.return

exception Aborted

class fetcher config trust_db (slave:Python.slave) =
  let system = config.system in

  let () =
    Python.register_handler "start-timeout" (function
      | [`String ticket] ->
          let timeout = StringMap.find ticket !timeout_tickets in
          timeout_tickets := StringMap.remove ticket !timeout_tickets;
          Lwt_timeout.start timeout;
          Lwt.return `Null
      | json -> raise_safe "start-timeout: invalid request: %s" (Yojson.Basic.to_string (`List json))
    ) in

  (** Download url to a new temporary file and return its name.
   * @param timeout_ticket a timer to start when the download starts (it will be queued first)
   * @hint a tag to attach to the download (used by the GUI to associate downloads with feeds)
   *)
  let download_url ?timeout_ticket ~hint url =
    let timeout_ticket =
      match timeout_ticket with
      | None -> `Null
      | Some ticket -> `String ticket in

    let request = `List [
      `String "download-url";
      `String url;
      `String hint;
      timeout_ticket;
    ] in

    slave#invoke_async request (function
      | `List [`String "success"; `String tmpname] -> `tmpfile tmpname
      | `String "aborted-by-user" -> `aborted_by_user
      | _ -> raise_safe "Invalid JSON response"
    ) in

  (** Check the GPG signatures on [tmpfile]. If any keys are missing, download and import them.
   * Returns a non-empty list of valid (though maybe not trusted) signatures, or a suitable error.
   * @param use_mirror the URL of the mirror server to use to get the keys, or None to use the primary site
   * @param feed the feed we're trying to import.
   * @param xml the new XML we are trying to verify
   *)
  let download_missing_keys ~use_mirror feed xml =
    lwt sigs, messages = G.verify system xml in

    if sigs = [] then (
      let extra = if messages = "" then "" else "\n" ^ messages in
      raise_safe "No signatures found on feed %s!%s" feed extra
    );

    let any_imported = ref false in

    let fetch key = (* Download a single key *)
      let key_url =
        match use_mirror with
        | None ->
            let last_slash = String.rindex feed '/' in
            String.sub feed 0 (last_slash + 1) ^ (key ^ ".gpg")
        | Some mirror -> mirror ^ "/keys/" ^ (key ^ ".gpg") in

      log_info "Fetching key from %s" key_url;

      match_lwt download_url ~hint:feed key_url with
      | `aborted_by_user -> raise Aborted
      | `tmpfile tmpfile ->
          let contents = U.read_file system tmpfile in
          system#unlink tmpfile;
          log_info "Importing key for feed '%s" feed;
          lwt () = G.import_key system contents in
          any_imported := true;
          Lwt.return () in

    (* Start a download for each missing key *)
    let missing_keys =
      sigs |> U.filter_map ~f:(function
        | G.ErrSig (G.UnknownKey key) -> Some (fetch key)
        | _ -> None
      ) in

    lwt errors = join_errors missing_keys in

    if List.mem Aborted errors then Lwt.return `aborted_by_user
    else (
      (* Recalculate signatures if we imported any new keys. *)
      lwt sigs, messages =
        if !any_imported then G.verify system xml
        else Lwt.return (sigs, messages) in

      let have_valid = sigs |> List.exists (function
        | G.ValidSig _ -> true
        | G.BadSig _ | G.ErrSig _ -> false
      ) in

      if have_valid then (
        errors |> List.iter (fun ex -> log_warning ~ex "Error downloading key for %s" feed);
        `success (sigs, messages) |> Lwt.return
      ) else (
        let msg = errors |> List.map Printexc.to_string |> String.concat ";" in
        `problem (Printf.sprintf "Error downloading key for '%s': %s" feed msg) |> Lwt.return
      )
    ) in

  (** Import a downloaded feed into the cache. We've already checked that we trust the
   * signature by this point. *)
  let update_feed_from_network feed new_xml timestamp =
    let pretty_time = timestamp |> Unix.localtime |> U.format_time_pretty in
    let `remote_feed feed_url = feed in
    log_debug "Updating '%s' from network; modified at %s" feed_url pretty_time;

    (* Check the new XML is valid before adding it *)
    let new_root = `String (0, new_xml) |> Xmlm.make_input |> Q.parse_input (Some feed_url) in
    let filtered = (Feed.parse system new_root None).Feed.root in

    let url_in_feed = ZI.get_attribute FeedAttr.uri new_root in
    if url_in_feed <> feed_url then
      Q.raise_elem "URL mismatch in feed:\n%s expected\n%s given in 'uri' attribute on" feed_url url_in_feed new_root;

    (* Load the old XML *)
    let cache_path = Feed_cache.get_save_cache_path config feed in
    let old_xml =
      if system#file_exists cache_path then
        Some (U.read_file system cache_path)
      else None in

    let success () =
      if not config.dry_run then (
        Feed.update_last_checked_time config feed_url;
        log_info "Updated feed cache checked time for %s (modified %s)" feed_url pretty_time
      );
      (* In dry-run mode we don't actually write to the cache, so we have to send the new
       * version to the Python. *)
      lwt () = slave#invoke_async ~xml:filtered (`List [`String "import-feed"]) (function
        | `Null -> ()
        | json -> raise_safe "Invalid JSON response '%s'" (Yojson.Basic.to_string json)
      ) in
      `ok new_root |> Lwt.return in

    if old_xml = Some new_xml then (
      log_debug "No change";
      success ()
    ) else (
      let save_new_xml () =
        if config.dry_run then (
          Dry_run.log "would cache feed %s as %s" feed_url cache_path
        ) else (
          system#atomic_write [Open_wronly; Open_binary] cache_path ~mode:0o644 (fun ch ->
            output_string ch new_xml
          );
          log_debug "Saved as %s" cache_path
        );
        success () in

      (* Check the timestamp is newer than the old version *)
      match old_xml with
      | None -> save_new_xml ()
      | Some old_xml ->
          lwt old_sigs, warnings = G.verify system old_xml in
          match trust_db#oldest_trusted_sig (Trust.domain_from_url feed_url) old_sigs with
          | None -> raise_safe "Can't check signatures of currently cached feed %s" warnings
          | Some old_modified when old_modified > timestamp ->
              `replay_attack (feed_url, old_modified, timestamp) |> Lwt.return
          | Some _ -> save_new_xml ()
    ) in

  (** We don't trust any of the signatures yet. Collect information about them and add the keys to the
      trust_db, possibly after confirming with the user. *)
  let confirm_keys feed sigs messages =
    let valid_sigs = U.filter_map sigs ~f:(function
      | G.ValidSig info -> Some info
      | G.BadSig _ | G.ErrSig _ -> None
    ) in

    if valid_sigs = [] then (
      let format_sig s = "\n- " ^ G.string_of_sig s in
      let extra =
        if messages = "" then ""
        else "\nMessages from GPG:\n" ^ messages in
      raise_safe "No valid signatures found on '%s'. Signatures:%s%s"
        feed (List.map format_sig sigs |> String.concat "") extra
    );

    let json_sigs = valid_sigs |> List.map (fun info -> `String info.G.fingerprint) in
    let request = `List [`String "confirm-keys"; `String feed; `List json_sigs] in
    slave#invoke_async request (function
      | `List confirmed_keys ->
          let domain = Trust.domain_from_url feed in
          confirmed_keys |> List.map Yojson.Basic.Util.to_string |> List.iter (trust_db#trust_key ~domain)
      | _ -> raise_safe "Invalid response"
    ) in

  (** We've just downloaded the new version of the feed to a temporary file. Check signature and import it into the cache. *)
  let import_feed ~mirror_used feed xml =
    let `remote_feed feed_url = feed in
    match_lwt download_missing_keys ~use_mirror:mirror_used feed_url xml with
    | `problem msg -> raise_safe "Failed to check feed signature: %s" msg
    | `aborted_by_user -> Lwt.return `aborted_by_user
    | `success (sigs, messages) ->
        match trust_db#oldest_trusted_sig (Trust.domain_from_url feed_url) sigs with
        | Some timestamp -> update_feed_from_network feed xml timestamp   (* We already trust a signing key *)
        | None ->
            lwt () = confirm_keys feed_url sigs messages in               (* Confirm keys with user *)
            match trust_db#oldest_trusted_sig (Trust.domain_from_url feed_url) sigs with
            | Some timestamp -> update_feed_from_network feed xml timestamp
            | None -> Lwt.return `no_trusted_keys
    in

  (* Try to download the feed [feed] from URL [url] (which is typically the same, unless we're
   * using a mirror.
   * If present, start [timeout] when the download actually starts (time spent queuing doesn't count). *)
  let download_and_import_feed_internal ~mirror_used ?timeout feed ~url =
    let `remote_feed feed_url = feed in

    let timeout_ticket =
      match timeout with
      | None -> None
      | Some timeout -> Some (take_ticket timeout) in

    if config.dry_run then
      Dry_run.log "downloading feed from %s" url;

    try_lwt
      match_lwt download_url ?timeout_ticket ~hint:feed_url url with
      | `aborted_by_user -> Lwt.return `aborted_by_user
      | `tmpfile tmpfile ->
          let xml = U.read_file system tmpfile in
          system#unlink tmpfile;
          import_feed ~mirror_used feed xml
    with Safe_exception (msg, _) ->
      `problem msg |> Lwt.return in

  (* The primary failed (already reported). Wait for the mirror. *)
  let wait_for_mirror mirror =
    match_lwt mirror with
    (* We already warned; no need to raise an exception too, as the mirror download succeeded. *)
    | `ok result -> `update (result, None) |> Lwt.return
    | `aborted_by_user -> `aborted_by_user |> Lwt.return
    | `replay_attack _ ->
        log_info "Version from mirror is older than cached version; ignoring it";
        Lwt.return `no_update
    | `no_trusted_keys ->
        Lwt.return `no_update
    | `problem msg ->
        log_info "Mirror download failed: %s" msg;
        Lwt.return `no_update in

  let wait_for_primary primary : _ Lwt.t =
    (* Wait for the primary (we're already got a response or failure from the mirror) *)
    match_lwt primary with
    | #non_mirror_case as result -> get_final_response result |> Lwt.return
    | `problem msg -> `problem (msg, None) |> Lwt.return in

  let escape_slashes s = Str.global_replace U.re_slash "%23" s in

  (* The algorithm from 0mirror. *)
  let get_feed_dir feed =
    if String.contains feed '#' then (
      raise_safe "Invalid URL '%s'" feed
    ) else (
      let scheme, rest = U.split_pair re_scheme_sep feed in
      if not (String.contains rest '/') then
        raise_safe "Missing / in %s" feed;
      let domain, rest = U.split_pair U.re_slash rest in
      [scheme; domain; rest] |> List.iter (fun part ->
        if part = "" || U.starts_with part "." then
          raise_safe "Invalid URL '%s'" feed
      );
      String.concat "/" ["feeds"; scheme; domain; escape_slashes rest]
    ) in

  let get_mirror_url mirror feed_url resource =
    if Str.string_match re_remote_feed feed_url 0 then (
      let scheme = Str.matched_group 1 feed_url in
      let domain = Str.matched_group 3 feed_url in
      match scheme with
      | "http" | "https" when domain <> "localhost" -> Some (mirror ^ "/" ^ (get_feed_dir feed_url) ^ "/" ^ resource)
      | _ -> None
    ) else (
      log_warning "Failed to parse URL '%s'" feed_url;
      None
    ) in

  (** Download a 0install implementation and add it to a store *)
  let download_impl (impl, _retrieval_method) : unit Lwt.t =
    let {Feed.feed; Feed.id} = Feed.get_id impl in

    let info = `Assoc [
      ("id", `String id);
      ("from-feed", `String feed);
    ] in

    let request : Yojson.Basic.json = `List [`String "download-impl"; info] in

    slave#invoke_async request (function
      | `List dry_run_paths ->
          (* In --dry-run mode, the directories haven't actually been added, so we need to tell the
           * dryrun_system about them. *)
          if config.dry_run then (
            List.iter (fun name -> system#mkdir (Yojson.Basic.Util.to_string name) 0o755) dry_run_paths
          )
      | `String "aborted-by-user" -> raise Aborted
      | json -> raise_safe "Invalid JSON response '%s'" (Yojson.Basic.to_string json)
    ) in

  object
    method download_and_import_feed (feed : [`remote_feed of feed_url]) : fetch_feed_response Lwt.t =
      let `remote_feed feed_url = feed in
      log_debug "download_and_import_feed %s" feed_url;

      if not config.dry_run then (
        Feed_cache.mark_as_checking config feed
      );
      
      let timeout_task, timeout_waker = Lwt.wait () in
      let timeout = Lwt_timeout.create 5 (fun () -> Lwt.wakeup timeout_waker `timeout) in

      let primary = download_and_import_feed_internal ~mirror_used:None feed ~timeout ~url:feed_url in
      let do_mirror_download () =
        try
          match config.mirror with
          | None -> None
          | Some mirror ->
              match get_mirror_url mirror feed_url "latest.xml" with
              | None -> None
              | Some mirror_url ->
                  Some (download_and_import_feed_internal ~mirror_used:(Some mirror) feed ~url:mirror_url)
        with ex ->
          log_warning ~ex "Error getting mirror URL for '%s" feed_url;
          None in

      (* Download just the upstream feed, unless it takes too long... *)
      match_lwt Lwt.choose [primary; timeout_task] with
      (* Downloaded feed within 5 seconds *)
      | #non_mirror_case as result -> get_final_response result |> Lwt.return
      | `problem msg -> (
          match do_mirror_download () with
          | None -> `problem (msg, None) |> Lwt.return
          | Some mirror -> `problem (msg, Some (wait_for_mirror mirror)) |> Lwt.return
      )
      | `timeout ->
          (* OK, maybe it's just being slow... *)
          log_info "Feed download from %s is taking a long time." feed_url;

          (* Start downloading from mirror... *)
          match do_mirror_download () with
          | None -> wait_for_primary primary
          | Some mirror ->
              (* Wait for a result from either *)
              lwt _ = Lwt.choose [primary; mirror] in

              match Lwt.state primary with
              | Lwt.Fail msg -> raise msg
              | Lwt.Sleep -> (
                  (* The mirror finished first *)
                  match_lwt mirror with
                  | `aborted_by_user ->
                      wait_for_primary primary
                  | `ok result ->
                      log_info "Mirror succeeded, but will continue to wait for primary";
                      `update (result, Some (wait_for_primary primary)) |> Lwt.return
                  | `replay_attack _ ->
                      log_info "Version from mirror is older than cached version; ignoring it";
                      wait_for_primary primary
                  | `no_trusted_keys ->
                      wait_for_primary primary
                  | `problem msg ->
                      log_info "Mirror download failed: %s" msg;
                      wait_for_primary primary
              )
              | Lwt.Return v -> (
                  (* The primary returned first *)
                  match v with
                  | #non_mirror_case as result ->
                      Lwt.cancel mirror;
                      get_final_response result |> Lwt.return
                  | `problem msg ->
                      `problem (msg, Some (wait_for_mirror mirror)) |> Lwt.return
              )

    method download_impls (impls:Feed.implementation list) : [ `success | `aborted_by_user ] Lwt.t =
      (* todo: external fetcher on Windows? *)

      let zi_impls = ref [] in
      let package_impls = ref [] in

      impls |> List.iter (fun impl ->
        let {Feed.feed; Feed.id} = Feed.get_id impl in
        let version = Feed.get_attr_ex FeedAttr.version impl in

        log_debug "download_impls: for %s get %s" feed version;

        match impl.Feed.impl_type with
        | Feed.PackageImpl info ->
            (* Any package without a retrieval method should be already installed *)
            let rm = info.Feed.retrieval_method |? lazy (raise_safe "Missing retrieval method for package '%s'" id) in
            package_impls := `Assoc rm :: !package_impls
        | Feed.LocalImpl path -> raise_safe "Can't fetch a missing local impl (%s from %s)!" path feed
        | Feed.CacheImpl info ->
            (* Pick the first retrieval method we understand *)
            match U.first_match info.Feed.retrieval_methods ~f:Recipe.parse_retrieval_method with
            | None -> raise_safe ("Implementation %s of interface %s cannot be downloaded " ^^
                                  "(no download locations given in feed!)") id feed
            | Some rm -> zi_impls := (impl, rm) :: !zi_impls
      );

    let packages_task =
      if !package_impls = [] then (
        Lwt.return ()
      ) else (
        let request = `List [`String "confirm-distro-install"; `List !package_impls] in
        slave#invoke_async request (function
          | `String "ok" -> ()
          | `String "aborted-by-user" -> raise Aborted
          | _ -> raise_safe "Invalid response"
        )
      ) in

    let zi_tasks = !zi_impls |> List.map download_impl in

    (** Wait for all downloads *)
    lwt errors = join_errors (packages_task :: zi_tasks) in

    if List.mem Aborted errors then Lwt.return `aborted_by_user
    else (
      match errors with
      | [] -> Lwt.return `success
      | first :: rest ->
          rest |> List.iter (fun ex -> log_warning ~ex "Download failed");
          raise first
    )

    method import_feed (feed_url:[`remote_feed of feed_url]) xml =
      match_lwt import_feed ~mirror_used:None feed_url xml with
      | `ok _ -> Lwt.return ()
      | (`aborted_by_user | `no_trusted_keys | `replay_attack _) as r -> raise_safe "%s" (string_of_result r)
  end
