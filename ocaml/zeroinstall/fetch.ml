(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
open Support.Common

module U = Support.Utils
module Q = Support.Qdom
module G = Support.Gpg
module FeedAttr = Constants.FeedAttr

type non_mirror_case = [ `Ok of [`Feed] Element.t | `No_trusted_keys | `Replay_attack of (Sigs.feed_url * float * float) | `Aborted_by_user ]

type fetch_feed_response =
  [ `Update of ([`Feed] Element.t * fetch_feed_response Lwt.t option)  (* Use this version (but a better version may come soon) *)
  | `Aborted_by_user        (* Abort silently (no need to notify the user) *)
  | `Problem of (string * fetch_feed_response Lwt.t option)    (* Report a problem (but may still succeed later) *)
  | `No_update ]            (* Use the previous version *)

let string_of_result = function
  | `Aborted_by_user -> "Aborted by user"
  | `No_trusted_keys -> "Not signed with a trusted key"
  | `Replay_attack (url, old_time, new_time) ->
      let old_time = old_time |> Unix.gmtime |> U.format_time in
      let new_time = new_time |> Unix.gmtime |> U.format_time in
      Printf.sprintf (
        "New feed's modification time is before old version!\n" ^^
        "Interface: %s\nOld time: %s\nNew time: %s\n" ^^
        "Refusing update.") url old_time new_time

(** Convert the status from the primary to our public return value. *)
let get_final_response = function
  | `Ok result -> `Update (result, None)
  | `Aborted_by_user -> `Aborted_by_user
  | `No_trusted_keys as r -> `Problem (string_of_result r, None)
  | `Replay_attack _ as r ->
      (* Don't bother trying the mirror if we have a replay attack *)
      `Problem (string_of_result r, None)

(** Wait for a set of tasks to complete. Return the exceptions produced by each, if any. *)
let rec join_errors = function
  | [] -> Lwt.return []
  | x :: xs ->
      Lwt.try_bind
        (fun () -> x)
        (fun () -> join_errors xs)
        (fun ex ->
           join_errors xs >|= fun exs ->
           ex :: exs
        )

let with_stores_tmpdir config fn =
  let need_rm_tmpdir = ref true in
  let switch = Lwt_switch.create () in
  let tmpdir = Stores.make_tmp_dir config.system#bypass_dryrun config.stores in
  Lwt.finalize
    (fun () -> fn ~switch ~need_rm_tmpdir tmpdir)
    (fun () ->
      Lwt_switch.turn_off switch >>= fun () ->
      try
        if !need_rm_tmpdir then (
          log_info "Removing temporary directory '%s'" tmpdir;
          U.rmtree ~even_if_locked:true config.system#bypass_dryrun tmpdir
        );
        Lwt.return ()
      with ex ->
        (* Don't mask the underlying error *)
        log_warning ~ex "Problem removing temporary directory";
        Lwt.return ()
    )

(* Takes a cross-platform relative path (i.e using forward slashes, even on windows)
   and returns the absolute, platform-native version of the path.
   If the path does not resolve to a location within [tmpdir], Safe_exception is raised.
   Resolving to base itself is also an error. *)
let native_path_within_base (system:system) ~tmpdir crossplatform_path =
  if U.starts_with crossplatform_path "/" then (
    raise_safe "Path %s is absolute!" crossplatform_path
  );
  let rec loop base = function
    | [] -> base
    | (""::xs) -> loop base xs
    | ("."::xs) -> loop base xs
    | (".."::_) -> raise_safe "Found '..' in path '%s' - disallowed" crossplatform_path
    | (x::xs) ->
        if String.contains x '\\' then
          raise_safe "Illegal character '\\' in path '%s' - disallowed" crossplatform_path;
        let new_base = base +/ x in
        match system#lstat new_base with
        | Some {Unix.st_kind = (Unix.S_DIR | Unix.S_REG); _} -> loop new_base xs
        | Some _ -> raise_safe "Refusing to follow non-file non-dir item '%s'" new_base
        | None -> loop new_base xs in
  let resolved = Str.split_delim U.re_slash crossplatform_path |> loop tmpdir in
  if resolved = tmpdir then
    raise_safe "Illegal path '%s'" crossplatform_path
  else
    resolved

exception Aborted
exception Try_mirror of string  (* An error where we should try the mirror (i.e. a network problem) *)

class fetcher config (trust_db:Trust.trust_db) distro (download_pool:Downloader.download_pool) (ui:#Progress.watcher) =
  let downloader = download_pool#with_monitor ui#monitor in

  let trust_dialog_lock = Lwt_mutex.create () in      (* Only show one trust dialog at a time *)

  let key_info_provider = Key_info_provider.make config in

  let system = config.system in
  let gpg = G.make system in

  (* Check the GPG signatures on [tmpfile]. If any keys are missing, download and import them.
   * Returns a non-empty list of valid (though maybe not trusted) signatures, or a suitable error.
   * @param use_mirror the URL of the mirror server to use to get the keys, or None to use the primary site
   * @param feed the feed we're trying to import.
   * @param xml the new XML we are trying to verify
   *)
  let download_missing_keys ~use_mirror feed_url xml =
    let `Remote_feed feed = feed_url in
    G.verify gpg xml >>= fun (sigs, messages) ->

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

      U.with_switch (fun switch ->
        Downloader.download downloader ~switch ~hint:feed_url key_url >>= function
        | `Network_failure msg -> raise_safe "%s" msg
        | `Aborted_by_user -> raise Aborted
        | `Tmpfile tmpfile ->
            let contents = U.read_file system tmpfile in
            log_info "Importing key for feed '%s" feed;
            G.import_key gpg contents >|= fun () ->
            any_imported := true
      ) in

    (* Start a download for each missing key *)
    let missing_keys =
      sigs |> U.filter_map (function
        | G.ErrSig (G.UnknownKey key) -> Some (fetch key)
        | _ -> None
      ) in

    join_errors missing_keys >>= fun errors ->

    if List.mem Aborted errors then Lwt.return `Aborted_by_user
    else (
      (* Recalculate signatures if we imported any new keys. *)
      begin
        if !any_imported then G.verify gpg xml
        else Lwt.return (sigs, messages)
      end >>= fun (sigs, messages) ->

      let have_valid = sigs |> List.exists (function
        | G.ValidSig _ -> true
        | G.BadSig _ | G.ErrSig _ -> false
      ) in

      if have_valid then (
        errors |> List.iter (fun ex -> log_warning ~ex "Error checking signature for %s" feed);
        `Success (sigs, messages) |> Lwt.return
      ) else (
        let msg = errors |> List.map Printexc.to_string |> String.concat ";" in
        let msg =
          if messages <> "" then msg ^ "\n" ^ messages
          else msg in
        `Problem (Printf.sprintf "Error checking signature for '%s': %s" feed msg) |> Lwt.return
      )
    ) in

  (* Import a downloaded feed into the cache. We've already checked that we trust the
   * signature by this point. *)
  let update_feed_from_network feed new_xml timestamp =
    let pretty_time = timestamp |> Unix.localtime |> U.format_time_pretty in
    let `Remote_feed feed_url = feed in
    log_debug "Updating '%s' from network; modified at %s" feed_url pretty_time;

    (* Check the new XML is valid before adding it *)
    let new_root = `String (0, new_xml) |> Xmlm.make_input |> Q.parse_input (Some feed_url) |> Element.parse_feed in
    ignore (Feed.parse system new_root None).Feed.root;

    let url_in_feed = Element.uri_exn new_root in
    if url_in_feed <> feed_url then
      raise_safe "URL mismatch in feed:\n%s expected\n%s given in 'uri' attribute on %a" feed_url url_in_feed Element.fmt new_root;

    (* Load the old XML *)
    let cache_path = Feed_cache.get_save_cache_path config feed in
    let old_xml =
      if system#file_exists cache_path then
        Some (U.read_file system cache_path)
      else None in

    let success () =
      if not config.dry_run then (
        Feed.update_last_checked_time config feed;
        log_info "Updated feed cache checked time for %s (modified %s)" feed_url pretty_time
      );
      `Ok new_root |> Lwt.return in

    if old_xml = Some new_xml then (
      log_debug "No change";
      success ()
    ) else (
      let save_new_xml () =
        if config.dry_run then (
          Dry_run.log "would cache feed %s as %s" feed_url cache_path
        ) else (
          cache_path |> system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
            output_string ch new_xml
          );
          log_debug "Saved as %s" cache_path
        );
        success () in

      (* Check the timestamp is newer than the old version *)
      match old_xml with
      | None -> save_new_xml ()
      | Some old_xml ->
          G.verify gpg old_xml >>= fun (old_sigs, warnings) ->
          match trust_db#oldest_trusted_sig (Trust.domain_from_url feed) old_sigs with
          | None -> raise_safe "Can't check signatures of currently cached feed %s" warnings
          | Some old_modified when old_modified > timestamp ->
              `Replay_attack (feed_url, old_modified, timestamp) |> Lwt.return
          | Some _ -> save_new_xml ()
    ) in

  (* We don't trust any of the signatures yet. Collect information about them and add the keys to the
     trust_db, possibly after confirming with the user. *)
  let confirm_keys feed sigs messages =
    let `Remote_feed feed_url = feed in
    let valid_sigs = sigs |> U.filter_map (function
      | G.ValidSig info -> Some info
      | G.BadSig _ | G.ErrSig _ -> None
    ) in

    if valid_sigs = [] then (
      let format_sig s = "\n- " ^ G.string_of_sig s in
      let extra =
        if messages = "" then ""
        else "\nMessages from GPG:\n" ^ messages in
      raise_safe "No valid signatures found on '%s'. Signatures:%s%s"
        feed_url (List.map format_sig sigs |> String.concat "") extra
    );

    (* Wait a while for the key information to arrive. Avoids having the dialog
     * box update while the user is looking at it, and allows it to be skipped
     * completely in many cases. *)
    let timeout_task, timeout_waker = Lwt.wait () in
    let if_slow = lazy (Lwt.wakeup timeout_waker []) in

    (* Start downloading information about the keys... *)
    let key_downloader ~switch url = Downloader.download downloader ~switch ~if_slow ~hint:feed url in
    let key_infos = valid_sigs |> List.map (fun {G.fingerprint; _} ->
      (fingerprint, Key_info_provider.get key_info_provider ~download:key_downloader fingerprint)
    ) in

    log_info "Waiting for response from key-info server...";
    Lwt.catch
      (fun () ->
         let key_tasks = key_infos |> List.map snd in
         Lwt.choose (timeout_task :: key_tasks) >|= ignore
      )
      (fun ex -> log_warning ~ex "Error looking up key information"; Lwt.return ())
    >>= fun () ->

    (* If we're already confirming something else, wait for that to finish... *)
    Lwt_mutex.with_lock trust_dialog_lock (fun () ->
      let domain = Trust.domain_from_url feed in

      (* When seeing a feed for the first time, we may be able to approve the keys automatically... *)
      if config.auto_approve_keys && Feed_cache.get_cached_feed_path config feed = None then (
        key_infos |> List.iter (fun (fingerprint, info) ->
          match Lwt.state info with
          | Lwt.Return votes -> (
              votes |> List.iter (fun (vote_type, msg) ->
                if vote_type = Progress.Good then (
                  log_info "Automatically approving key for new feed %s based on response from key info server: %s" feed_url msg;
                  trust_db#trust_key ~domain fingerprint
                ) else (
                  log_info "Ignoring bad response for %s: %s" fingerprint msg   (* Abort here? *)
                )
              )
          )
          | _ -> ()
        );
      );

      (* Check whether we still need to confirm. The user may have
       * already approved one of the keys while dealing with another
       * feed, or we may have just auto-approved it. *)
      let is_trusted {G.fingerprint; _} = trust_db#is_trusted ~domain fingerprint in
      if (List.exists is_trusted valid_sigs) then Lwt.return ()
      else (
        ui#confirm_keys feed key_infos >|= List.iter (fun fingerprint ->
          log_info "Trusting %s for %s" fingerprint domain;
          trust_db#trust_key ~domain fingerprint
        )
      )
    ) in

  (* We've just downloaded the new version of the feed to a temporary file. Check signature and import it into the cache. *)
  let import_feed ~mirror_used feed xml =
    download_missing_keys ~use_mirror:mirror_used feed xml >>= function
    | `Problem msg -> raise_safe "Failed to check feed signature: %s" msg
    | `Aborted_by_user -> Lwt.return `Aborted_by_user
    | `Success (sigs, messages) ->
        match trust_db#oldest_trusted_sig (Trust.domain_from_url feed) sigs with
        | Some timestamp -> update_feed_from_network feed xml timestamp   (* We already trust a signing key *)
        | None ->
            confirm_keys feed sigs messages >>= fun () ->                 (* Confirm keys with user *)
            match trust_db#oldest_trusted_sig (Trust.domain_from_url feed) sigs with
            | Some timestamp -> update_feed_from_network feed xml timestamp
            | None -> Lwt.return `No_trusted_keys
    in

  (* Try to download the feed [feed] from URL [url] (which is typically the same, unless we're
   * using a mirror.
   * If present, start [timeout] when the download actually starts (time spent queuing doesn't count). *)
  let download_and_import_feed_internal ~mirror_used ?if_slow feed ~url =
    if config.dry_run then
      Dry_run.log "downloading feed from %s" url;

    U.with_switch (fun switch ->
      Downloader.download downloader ~switch ?if_slow ~hint:feed url >>= function
      | `Network_failure msg -> `Problem msg |> Lwt.return
      | `Aborted_by_user -> Lwt.return `Aborted_by_user
      | `Tmpfile tmpfile ->
          let xml = U.read_file system tmpfile in
          Lwt_switch.turn_off switch >>= fun () ->
          import_feed ~mirror_used feed xml
    ) in

  (* The primary failed (already reported). Wait for the mirror. *)
  let wait_for_mirror mirror =
    mirror >>= function
    (* We already warned; no need to raise an exception too, as the mirror download succeeded. *)
    | `Ok result -> `Update (result, None) |> Lwt.return
    | `Aborted_by_user -> `Aborted_by_user |> Lwt.return
    | `Replay_attack _ ->
        log_info "Version from mirror is older than cached version; ignoring it";
        Lwt.return `No_update
    | `No_trusted_keys ->
        Lwt.return `No_update
    | `Problem msg ->
        log_info "Mirror download failed: %s" msg;
        Lwt.return `No_update in

  let wait_for_primary primary : _ Lwt.t =
    (* Wait for the primary (we're already got a response or failure from the mirror) *)
    primary >>= function
    | #non_mirror_case as result -> get_final_response result |> Lwt.return
    | `Problem msg -> `Problem (msg, None) |> Lwt.return in

  let download_local_file feed size fn url =
    let size = size |? lazy (raise_safe "Missing size (BUG)!") in   (* Only missing for mirror downloads, which are never local *)
    match feed with
    | `Distribution_feed _ -> assert false
    | `Remote_feed feed_url ->
        raise_safe "Relative URL '%s' in non-local feed '%s'" url feed_url
    | `Local_feed feed_path ->
        let path = Filename.dirname feed_path +/ url in
        match system#stat path with
        | Some info ->
            let actual_size = info.Unix.st_size in    (* Have to work with poor OCaml API here *)
            let expected_size = Int64.to_int size in
            if actual_size = expected_size then
              lazy (fn path) |> Lwt.return
            else
              raise_safe "Wrong size for %s: feed says %d, but actually %d bytes" path expected_size actual_size;
        | None -> raise_safe "Local file '%s' does not exist" path in

  let download_file ~switch ~start_offset ~feed ?size ~may_use_mirror fn url =
    if Str.string_match (Str.regexp "[a-z]+://") url 0 then (
      (* Remote file *)
      if config.dry_run then
        Dry_run.log "downloading %s" url;
      let mirror_url = if may_use_mirror then Mirror.for_archive config url else None in
      Downloader.download downloader ~switch ?size ~start_offset ~hint:feed url >>= function
      | `Aborted_by_user -> raise Aborted
      | `Tmpfile tmpfile -> lazy (fn tmpfile) |> Lwt.return
      | `Network_failure primary_msg ->
          (* There are two mirror systems in use here. First, we try our [mirror_url]. If that fails too,
           * we raise [Try_mirror] to try the other strategy. *)
          let mirror_url = mirror_url |? lazy (raise (Try_mirror primary_msg)) in
          log_info "Download failed: %s" primary_msg;
          log_warning "Primary download failed; trying mirror URL '%s'..." mirror_url;
          Downloader.download downloader ~switch ?size ~hint:feed mirror_url >>= function
          | `Aborted_by_user -> raise Aborted
          | `Tmpfile tmpfile -> lazy (fn tmpfile) |> Lwt.return
          | `Network_failure mirror_msg ->
              log_debug "Mirror failed too: %s" mirror_msg;
              raise (Try_mirror primary_msg)
    ) else (
      download_local_file feed size fn url
    ) in

  let download_archive ~switch ~feed ?size ~may_use_mirror fn (url, archive_info) =
    let open Recipe in
    let {start_offset; mime_type; extract = _; dest = _} = archive_info in
    let mime_type = mime_type |? lazy (Archive.type_from_url url) in

    Archive.check_type_ok system mime_type;

    let size =
      match size with
      | None -> None (* (don't know sizes for mirrored archives) *)
      | Some size -> Some (Int64.add size start_offset) in

    download_file ~switch ~feed ?size ~start_offset ~may_use_mirror fn url in

  (* Download an implementation by following a recipe and add it to the store.
   * (this was called "cook" in the Python version)
   * @param may_use_mirror if failed archives should be retried with the mirror
   *        ([true] normally, [false] if this is a mirror download itself)
   * @return `Network_failure for problems which can be tried with the mirror
   *)
  let download_impl_internal ~may_use_mirror impl required_digest retrieval_method =
    let {Feed_url.feed; Feed_url.id = _} = Impl.get_id impl in
    (* Start all the downloads. The downloads happen in parallel, each returning
     * a future that will perform the extraction step. These futures are evaluated in sequence. *)
    with_stores_tmpdir config (fun ~switch ~need_rm_tmpdir tmpdir ->
        let native_path_within_base = native_path_within_base config.system ~tmpdir in
        Lwt.catch
          (fun () ->
            let open Recipe in
            let real_system = system#bypass_dryrun in    (* We really do extract to the temporary directory *)
            let downloads = retrieval_method |> List.map (function
              | DownloadStep {url; size; download_type = ArchiveDownload archive_info} ->
                  (url, archive_info) |> download_archive ~switch ~may_use_mirror ?size ~feed (fun tmpfile ->
                    let {extract; start_offset = _; mime_type; dest} = archive_info in
                    let basedir =
                      match dest with
                      | None -> tmpdir
                      | Some dest ->
                          let basedir = native_path_within_base dest in
                          U.makedirs real_system basedir 0o755;
                          basedir in
                    let mime_type = mime_type |? lazy (Archive.type_from_url url) in
                    with_error_info (fun f -> f "... unpacking archive '%s'" url) (fun () ->
                        Archive.unpack_over {config with system = system#bypass_dryrun}
                          ~archive:tmpfile ~tmpdir:(Filename.dirname tmpdir)
                          ~destdir:basedir ?extract ~mime_type
                      )
                  )
              | DownloadStep {url; size; download_type = FileDownload dest} ->
                  url |> download_file ~switch ?size ~start_offset:Int64.zero ~feed ~may_use_mirror:false (fun tmpfile ->
                    let dest = native_path_within_base dest in
                    U.makedirs real_system (Filename.dirname dest) 0o755;
                    U.copy_file real_system tmpfile dest 0o644;
                    system#bypass_dryrun#set_mtime dest 0.0;
                    Lwt.return ()
                  )
              | RenameStep {rename_source; rename_dest} -> lazy (
                  let source = native_path_within_base rename_source in
                  let dest = native_path_within_base rename_dest in
                  try
                    U.makedirs real_system (Filename.dirname dest) 0o755;
                    real_system#rename source dest;
                    Lwt.return ()
                  with Unix.Unix_error (Unix.ENOENT, _, _) as ex ->
                    log_info ~ex "Failed to rename %s -> %s" source dest;
                    raise_safe "<rename> source '%s' does not exist" source
              ) |> Lwt.return
              | RemoveStep {remove} -> lazy (
                  let path = native_path_within_base remove in
                  U.rmtree ~even_if_locked:true real_system path;
                  Lwt.return ()
              ) |> Lwt.return
            ) in

            (* Now do all the steps in series. *)
            downloads |> Lwt_list.iter_s (fun fn ->
              fn >>= Lazy.force
            ) >>= fun () ->

            Stores.check_manifest_and_rename {config with system = system#bypass_dryrun} required_digest tmpdir >>= fun () ->
            ui#impl_added_to_store; (* Notify the GUI *)
            need_rm_tmpdir := false;
            Lwt.return `Success
          )
          (function
            | Aborted -> `Aborted_by_user |> Lwt.return
            | Try_mirror msg -> `Network_failure msg |> Lwt.return
            | ex -> Lwt.fail ex
          )
      ) in

  (* Download a 0install implementation and add it to a store *)
  let download_impl (impl, required_digest, retrieval_method) : unit Lwt.t =
    let download ~may_use_mirror recipe = download_impl_internal ~may_use_mirror impl required_digest recipe in
    with_error_info (fun f ->
        let {Feed_url.feed; Feed_url.id} = Impl.get_id impl in
        let version = Impl.get_attr_ex FeedAttr.version impl in
        f "... downloading implementation %s %s (id=%s)" (Feed_url.format_url feed) version id
      ) (fun () ->
        download ~may_use_mirror:true retrieval_method >>= function
        | `Success -> Lwt.return ()
        | `Aborted_by_user -> raise Aborted
        | `Network_failure orig_msg ->
            let mirror_download = Mirror.for_impl config impl |? lazy (raise_safe "%s" orig_msg) in
            log_info "%s: trying implementation mirror at %s" orig_msg (config.mirror |> default "-");
            download ~may_use_mirror:false mirror_download >>= function
            | `Aborted_by_user -> raise Aborted
            | `Success -> Lwt.return ()
            | `Network_failure mirror_msg ->
                log_info "Error from mirror: %s" mirror_msg;
                raise_safe "%s" orig_msg
      ) in

  object
    method download_and_import_feed (feed : [`Remote_feed of Sigs.feed_url]) : fetch_feed_response Lwt.t =
      let `Remote_feed feed_url = feed in
      log_debug "download_and_import_feed %s" feed_url;

      if not config.dry_run then (
        Feed_cache.mark_as_checking config feed
      );

      let timeout_task, timeout_waker = Lwt.wait () in
      let if_slow = lazy (Lwt.wakeup timeout_waker `Timeout) in

      let primary = download_and_import_feed_internal ~mirror_used:None feed ~if_slow ~url:feed_url in
      let do_mirror_download () =
        try
          Mirror.for_feed config feed |> pipe_some (fun mirror_url ->
            Some (download_and_import_feed_internal ~mirror_used:config.mirror feed ~url:mirror_url)
          )
        with ex ->
          log_warning ~ex "Error getting mirror URL for '%s" feed_url;
          None in

      (* Download just the upstream feed, unless it takes too long... *)
      Lwt.choose [primary; timeout_task] >>= function
      (* Downloaded feed within 5 seconds *)
      | #non_mirror_case as result -> get_final_response result |> Lwt.return
      | `Problem msg -> (
          match do_mirror_download () with
          | None -> `Problem (msg, None) |> Lwt.return
          | Some mirror -> `Problem (msg, Some (wait_for_mirror mirror)) |> Lwt.return
      )
      | `Timeout ->
          (* OK, maybe it's just being slow... *)
          log_info "Feed download from %s is taking a long time." feed_url;

          (* Start downloading from mirror... *)
          match do_mirror_download () with
          | None -> wait_for_primary primary
          | Some mirror ->
              (* Wait for a result from either *)
              Lwt.choose [primary; mirror] >>= fun _ ->

              match Lwt.state primary with
              | Lwt.Fail msg -> raise msg
              | Lwt.Sleep -> (
                  (* The mirror finished first *)
                  mirror >>= function
                  | `Aborted_by_user ->
                      wait_for_primary primary
                  | `Ok result ->
                      log_info "Mirror succeeded, but will continue to wait for primary";
                      `Update (result, Some (wait_for_primary primary)) |> Lwt.return
                  | `Replay_attack _ ->
                      log_info "Version from mirror is older than cached version; ignoring it";
                      wait_for_primary primary
                  | `No_trusted_keys ->
                      wait_for_primary primary
                  | `Problem msg ->
                      log_info "Mirror download failed: %s" msg;
                      wait_for_primary primary
              )
              | Lwt.Return v -> (
                  (* The primary returned first *)
                  match v with
                  | #non_mirror_case as result ->
                      Lwt.cancel mirror;
                      get_final_response result |> Lwt.return
                  | `Problem msg ->
                      `Problem (msg, Some (wait_for_mirror mirror)) |> Lwt.return
              )

    method download_impls (impls:Impl.existing Impl.t list) : [ `Success | `Aborted_by_user ] Lwt.t =
      (* todo: external fetcher on Windows? *)

      let zi_impls = ref [] in
      let package_impls = ref [] in

      impls |> List.iter (fun impl ->
        let {Feed_url.feed; Feed_url.id} = Impl.get_id impl in
        let version = Impl.get_attr_ex FeedAttr.version impl in

        log_debug "download_impls: for %s get %s" (Feed_url.format_url feed) version;

        match impl with
        | {Impl.impl_type = `Package_impl info; _} as impl ->
            if info.Impl.package_state = `Installed then
              log_warning "Package '%s' already installed; skipping" (Impl.get_id impl).Feed_url.id
            else
              package_impls := impl :: !package_impls
        | {Impl.impl_type = `Local_impl path; _} -> raise_safe "Can't fetch a missing local impl (%s from %s)!" path (Feed_url.format_url feed)
        | {Impl.impl_type = `Cache_impl info; _} ->
            (* Choose the best digest algorithm we support *)
            if info.Impl.digests = [] then (
              raise_safe "No digests at all! (so can't choose best) on %a" Impl.fmt impl
            );
            let digest = Stores.best_digest info.Impl.digests in

            (* Pick the first retrieval method we understand *)
            match info.Impl.retrieval_methods |> U.first_match Recipe.parse_retrieval_method with
            | None -> raise_safe ("Implementation %s of interface %s cannot be downloaded " ^^
                                  "(no download locations given in feed!)") id (Feed_url.format_url feed)
            | Some rm -> zi_impls := (impl, digest, rm) :: !zi_impls
      );

    let packages_task =
      if !package_impls <> [] then (
        Distro.install_distro_packages distro ui !package_impls >>= function
        | `Cancel -> Lwt.fail Aborted
        | `Ok -> Lwt.return ()
      ) else Lwt.return () in

    let zi_tasks = !zi_impls |> List.map download_impl in

    (* Wait for all downloads *)
    join_errors (packages_task :: zi_tasks) >>= fun errors ->

    if List.mem Aborted errors then Lwt.return `Aborted_by_user
    else (
      match errors with
      | [] -> Lwt.return `Success
      | first :: rest ->
          rest |> List.iter (fun ex -> log_warning ~ex "Download failed");
          raise first
    )

    method import_feed (feed_url:[`Remote_feed of Sigs.feed_url]) xml =
      import_feed ~mirror_used:None feed_url xml >>= function
      | `Ok _ -> Lwt.return ()
      | (`Aborted_by_user | `No_trusted_keys | `Replay_attack _) as r -> raise_safe "%s" (string_of_result r)

    method download_icon (feed_url:Feed_url.non_distro_feed) icon_url =
      let modification_time =
        Feed_cache.get_cached_icon_path config feed_url
        |> pipe_some system#stat
        |> pipe_some (fun info -> Some info.Unix.st_mtime) in

      U.with_switch (fun switch ->
        Downloader.download_if_unmodified downloader ~switch ?modification_time ~hint:feed_url icon_url >|= function
        | `Network_failure msg -> raise_safe "%s" msg
        | `Aborted_by_user -> ()
        | `Unmodified -> ()
        | `Tmpfile tmpfile ->
            let icon_file = Paths.Cache.(save_path (icon feed_url)) config.paths in
            tmpfile |> system#with_open_in [Open_rdonly;Open_binary] (fun ic ->
              icon_file |> system#atomic_write [Open_wronly;Open_binary] ~mode:0o644 (U.copy_channel ic)
            )
      )

    method ui = (ui :> Progress.watcher)
  end

(** If [ZEROINSTALL_EXTERNAL_FETCHER] is set, we override [download_impls] to ask an
 * external process to do the downloading and unpacking. This is needed on Windows
 * because X bits need some special support that is implemented in .NET. *)
class external_fetcher command underlying =
  let rec add_mime_types node =
    match ZI.tag node with
    | Some "recipe" ->
        { node with Q.child_nodes = node.Q.child_nodes |> List.map add_mime_types }
    | Some "archive" when ZI.get_attribute_opt "type" node = None ->
        let mime_type = ZI.get_attribute "href" node |> Archive.type_from_url in
        { node with Q.attrs = node.Q.attrs |> Q.AttrMap.add_no_ns "type" mime_type }
    | _ -> node in

  object (_ : #fetcher)
    method import_feed = underlying#import_feed
    method download_icon = underlying#download_icon
    method download_and_import_feed = underlying#download_and_import_feed
    method ui = underlying#ui

    method download_impls impls =
      with_error_info (fun f -> f "... downloading with external fetcher '%s'" command) @@ fun () ->
      let child_nodes = impls |> List.map (function
        | { qdom; Impl.impl_type = `Cache_impl { Impl.digests; _}; _} ->
            let qdom = Element.as_xml qdom in
            let attrs = ref Q.AttrMap.empty in
            digests |> List.iter (fun (name, value) ->
              attrs := !attrs |> Q.AttrMap.add_no_ns name value
            );
            let manifest_digest = ZI.make ~attrs:!attrs "manifest-digest" in
            let child_nodes = qdom.Q.child_nodes |> List.map add_mime_types in
            { qdom with
              Q.child_nodes = manifest_digest :: child_nodes
            }
        | impl -> Element.as_xml impl.Impl.qdom
      ) in
      let root = ZI.make ~child_nodes "interface" in

      (* Crazy Lwt API to split a command into words and search in PATH *)
      let lwt_command = ("", [| "\000" ^ command |]) in

      log_info "Running external fetcher: %s" command;
      let child = Lwt_process.open_process_full lwt_command in

      (* .NET helper API wants an XML document with no line-breaks. Multi-line fields
       * aren't used for anything here, so just replace with spaces. *)
      let msg = Q.to_utf8 root |> String.map (function '\n' -> ' ' | x -> x) in
      log_debug "Sending XML to fetcher process:\n%s" msg;
      let stdin = Lwt_io.write child#stdin (msg ^ "\n") >>= fun () -> Lwt_io.close child#stdin in
      let output = Lwt_io.read child#stdout in
      let errors = Lwt_io.read child#stderr in
      stdin >>= fun () ->
      output >>= fun output ->
      errors >>= fun errors ->
      log_debug "External fetch process complete";
      with_error_info (fun f -> f "stdout: %s\nstderr: %s" output errors)
        (fun () ->
          child#close >|= fun status ->
          Support.System.check_exit_status status;
          `Success
        )

  end

let make config trust_db distro download_pool ui =
  let fetcher = new fetcher config trust_db distro download_pool ui in
  match config.system#getenv "ZEROINSTALL_EXTERNAL_FETCHER" with
  | None -> fetcher
  | Some command ->
      try new external_fetcher command fetcher
      with Safe_exception _ as ex -> reraise_with_context ex "... handling $ZEROINSTALL_EXTERNAL_FETCHER"
