(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
open Support.Common

module U = Support.Utils
module Q = Support.Qdom
module G = Support.Gpg
module FeedAttr = Constants.FeedAttr

let key_info_timeout = 10	(* Maximum time to wait for response from key-info-server before showing the dialog anyway *)

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

let re_remote_feed = Str.regexp "^\\(https?\\)://\\([^/]*@\\)?\\([^/:]+\\)\\(:[^/]*\\)?/"

(** Wait for a set of tasks to complete. Return the exceptions produced by each, if any. *)
let rec join_errors = function
  | [] -> Lwt.return []
  | x :: xs ->
      try_lwt lwt () = x in join_errors xs
      with ex ->
        lwt exs = join_errors xs in
        ex :: exs |> Lwt.return

let maybe = function
  | Some v -> `String v
  | None -> `Null

exception Aborted
exception Try_mirror of string  (* An error where we should try the mirror (i.e. a network problem) *)

class fetcher config trust_db (slave:Python.slave) (downloader:Downloader.downloader) =
  let trust_dialog_lock = Lwt_mutex.create () in      (* Only show one trust dialog at a time *)

  let key_info_cache = Hashtbl.create 10 in

  let system = config.system in

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

      let switch = Lwt_switch.create () in
      try_lwt
        match_lwt downloader#download ~switch ~hint:feed key_url with
        | `network_failure msg -> raise_safe "%s" msg
        | `aborted_by_user -> raise Aborted
        | `tmpfile tmpfile ->
            let contents = U.read_file system tmpfile in
            log_info "Importing key for feed '%s" feed;
            lwt () = G.import_key system contents in
            any_imported := true;
            Lwt.return ()
      finally
        Lwt_switch.turn_off switch in

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
    ignore (Feed.parse system new_root None).Feed.root;

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
          match trust_db#oldest_trusted_sig (Trust.domain_from_url feed) old_sigs with
          | None -> raise_safe "Can't check signatures of currently cached feed %s" warnings
          | Some old_modified when old_modified > timestamp ->
              `replay_attack (feed_url, old_modified, timestamp) |> Lwt.return
          | Some _ -> save_new_xml ()
    ) in

  let fetch_key_info ~hint fingerprint : Q.element list Lwt.t =
    try
      let result = Hashtbl.find key_info_cache fingerprint in
      match Lwt.state result with
      | Lwt.Return _ | Lwt.Sleep -> result
      | Lwt.Fail _ -> raise Not_found (* Retry *)
    with Not_found ->
      let result =
        match config.key_info_server with
        | None -> Lwt.return []
        | Some key_info_server ->
            if config.dry_run then (
              Dry_run.log "asking %s about key %s" key_info_server fingerprint;
            );
            let key_info_url = key_info_server ^ "/key/" ^ fingerprint in
            let switch = Lwt_switch.create () in
            try_lwt
              match_lwt downloader#download ~hint key_info_url with
              | `network_failure msg -> raise_safe "%s" msg
              | `aborted_by_user -> raise Aborted
              | `tmpfile tmpfile ->
                  let contents = U.read_file system tmpfile in
                  system#unlink tmpfile;
                  let root = `String (0, contents) |> Xmlm.make_input |> Q.parse_input (Some key_info_url) in
                  if root.Q.tag <> ("", "key-lookup") then (
                    Q.raise_elem "Expected <key-lookup>, not " root
                  );
                  Lwt.return root.Q.child_nodes
            finally
              Lwt_switch.turn_off switch in
      Hashtbl.add key_info_cache fingerprint result;
      result in

  (** We don't trust any of the signatures yet. Collect information about them and add the keys to the
      trust_db, possibly after confirming with the user. *)
  let confirm_keys feed sigs messages =
    let `remote_feed feed_url = feed in
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
        feed_url (List.map format_sig sigs |> String.concat "") extra
    );

    (* Start downloading information about the keys... *)
    let key_infos = valid_sigs |> List.map (fun {G.fingerprint; _} ->
      (fingerprint, fetch_key_info ~hint:feed_url fingerprint)
    ) in

    (* Wait up to key_info_timeout seconds for key information to arrive. Avoids having the dialog
     * box update while the user is looking at it, and allows it to be skipped completely in many
     * cases. *)
    let timeout_task, timeout_waker = Lwt.wait () in
    Lwt_timeout.create key_info_timeout (fun () -> Lwt.wakeup timeout_waker []) |> Lwt_timeout.start;

    log_info "Waiting for response from key-info server...";
    lwt () =
      let key_tasks = key_infos |> List.map snd in
      try_lwt
        lwt _ = Lwt.choose (timeout_task :: key_tasks) in Lwt.return ()
      with ex -> log_warning ~ex "Error looking up key information"; Lwt.return () in

    (* If we're already confirming something else, wait for that to finish... *)
    Lwt_mutex.with_lock trust_dialog_lock (fun () ->
      let domain = Trust.domain_from_url feed in

      (* When seeing a feed for the first time, we may be able to approve the keys automatically... *)
      if config.auto_approve_keys && Feed_cache.get_cached_feed_path config feed = None then (
        key_infos |> List.iter (fun (fingerprint, info) ->
          match Lwt.state info with
          | Lwt.Return votes -> (
              votes |> List.iter (fun xml ->
                if Q.get_attribute_opt ("", "vote") xml = Some "good" then (
                  let msg = xml.Q.last_text_inside in
                  log_info "Automatically approving key for new feed %s based on response from key info server: %s" feed_url msg;
                  trust_db#trust_key ~domain fingerprint
                ) else (
                  log_info "Ignoring bad response for %s: %s" fingerprint xml.Q.last_text_inside   (* Abort here? *)
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
        let xml = ZI.make_root "votes" in
        key_infos |> List.iter (fun (fingerprint, info) ->
          let elem = ZI.insert_first "result" xml in
          Q.set_attribute "fingerprint" fingerprint elem;
          match Lwt.state info with
          | Lwt.Return votes -> elem.Q.child_nodes <- votes |> List.map (fun v -> Q.import_node v elem.Q.doc)
          | Lwt.Fail ex -> Q.set_attribute "error" (Printexc.to_string ex) elem
          | Lwt.Sleep ->
              Q.set_attribute "pending" "true" elem;
              Python.async (fun () ->
                lwt info = info in
                let root = ZI.make_root "votes" in
                root.Q.child_nodes <- info |> List.map (fun v -> Q.import_node v root.Q.doc);
                slave#invoke_async ~xml:root (`List [`String "update-key-info"; `String fingerprint]) ignore
              )
        );
        let request = `List [`String "confirm-keys"; `String feed_url] in
        slave#invoke_async ~xml request (function
          | `List confirmed_keys ->
              confirmed_keys |> List.map Yojson.Basic.Util.to_string |> List.iter (trust_db#trust_key ~domain)
          | _ -> raise_safe "Invalid response"
        );
      )
    ) in

  (** We've just downloaded the new version of the feed to a temporary file. Check signature and import it into the cache. *)
  let import_feed ~mirror_used feed xml =
    let `remote_feed feed_url = feed in
    match_lwt download_missing_keys ~use_mirror:mirror_used feed_url xml with
    | `problem msg -> raise_safe "Failed to check feed signature: %s" msg
    | `aborted_by_user -> Lwt.return `aborted_by_user
    | `success (sigs, messages) ->
        match trust_db#oldest_trusted_sig (Trust.domain_from_url feed) sigs with
        | Some timestamp -> update_feed_from_network feed xml timestamp   (* We already trust a signing key *)
        | None ->
            lwt () = confirm_keys feed sigs messages in               (* Confirm keys with user *)
            match trust_db#oldest_trusted_sig (Trust.domain_from_url feed) sigs with
            | Some timestamp -> update_feed_from_network feed xml timestamp
            | None -> Lwt.return `no_trusted_keys
    in

  (* Try to download the feed [feed] from URL [url] (which is typically the same, unless we're
   * using a mirror.
   * If present, start [timeout] when the download actually starts (time spent queuing doesn't count). *)
  let download_and_import_feed_internal ~mirror_used ?timeout feed ~url =
    let `remote_feed feed_url = feed in

    if config.dry_run then
      Dry_run.log "downloading feed from %s" url;

    let switch = Lwt_switch.create () in
    try_lwt
      match_lwt downloader#download ~switch ?timeout ~hint:feed_url url with
      | `network_failure msg -> `problem msg |> Lwt.return
      | `aborted_by_user -> Lwt.return `aborted_by_user
      | `tmpfile tmpfile ->
          let xml = U.read_file system tmpfile in
          lwt () = Lwt_switch.turn_off switch in
          import_feed ~mirror_used feed xml
    finally
      Lwt_switch.turn_off switch in

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

  (* Don't bother trying the mirror for localhost URLs. *)
  let can_try_mirror url =
    if Str.string_match re_remote_feed url 0 then (
      let scheme = Str.matched_group 1 url in
      let domain = Str.matched_group 3 url in
      match scheme with
      | "http" | "https" when domain <> "localhost" -> true
      | _ -> false
    ) else (
      log_warning "Failed to parse URL '%s'" url;
      false
    ) in

  let get_mirror_url mirror feed_url resource =
    match Feed_cache.parse_feed_url feed_url with
    | `local_feed _ | `distribution_feed _ -> None
    | `remote_feed _ ->
        if can_try_mirror feed_url then
          Some (mirror ^ "/" ^ (get_feed_dir feed_url) ^ "/" ^ resource)
        else None in

  (** Get a recipe for the tar.bz2 of the implementation at the mirror.
   * Note: This is just one way we try the mirror. Code elsewhere checks for mirrors of the individual archives.
   * This is for a single archive containing the whole implementation. *)
  let get_impl_mirror_recipe mirror impl =
    let {Feed.feed; Feed.id} = Feed.get_id impl in
    match get_mirror_url mirror feed ("impl/" ^ escape_slashes id) with
    | None -> None
    | Some url -> Some (Recipe.get_mirror_download url) in

  let download_local_file feed size fn url =
    let size = size |? lazy (raise_safe "Missing size (BUG)!") in   (* Only missing for mirror downloads, which are never local *)
    match Feed_cache.parse_feed_url feed with
    | `distribution_feed _ -> assert false
    | `remote_feed feed_url ->
        raise_safe "Relative URL '%s' in non-local feed '%s'" url feed_url
    | `local_feed feed_path ->
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

  let download_file ~switch ~feed ?size ~may_use_mirror fn url =
    if Str.string_match (Str.regexp "[a-z]+://") url 0 then (
      (* Remote file *)
      if config.dry_run then
        Dry_run.log "downloading %s" url;
      let mirror_url =
        match config.mirror with
        | Some mirror when may_use_mirror && can_try_mirror url ->
            let escaped = Str.global_replace (Str.regexp_string "/") "#" url |> Curl.escape in
            Some (mirror ^ "/archive/" ^ escaped)
        | _ -> None in
      match_lwt downloader#download ~switch ?size ~hint:feed url with
      | `aborted_by_user -> raise Aborted
      | `tmpfile tmpfile -> lazy (fn tmpfile) |> Lwt.return
      | `network_failure primary_msg ->
          (* There are two mirror systems in use here. First, we try our [mirror_url]. If that fails too,
           * we raise [Try_mirror] to try the other strategy. *)
          let mirror_url = mirror_url |? lazy (raise (Try_mirror primary_msg)) in
          log_warning "Primary download failed; trying mirror URL '%s'..." mirror_url;
          match_lwt downloader#download ~switch ?size ~hint:feed mirror_url with
          | `aborted_by_user -> raise Aborted
          | `tmpfile tmpfile -> lazy (fn tmpfile) |> Lwt.return
          | `network_failure mirror_msg ->
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

    download_file ~switch ~feed ?size ~may_use_mirror fn url in

  (* Download an implementation by following a recipe and add it to the store.
   * (this was called "cook" in the Python version)
   * @param may_use_mirror if failed archives should be retried with the mirror
   *        ([true] normally, [false] if this is a mirror download itself)
   * @return `network_failure for problems which can be tried with the mirror
   *)
  let download_impl_internal ~may_use_mirror impl required_digest retrieval_method =
    let need_rm_tmpdir = ref true in
    let tmpdir = Stores.make_tmp_dir config.system#bypass_dryrun config.stores in

    (** Takes a cross-platform relative path (i.e using forward slashes, even on windows)
        and returns the absolute, platform-native version of the path.
        If the path does not resolve to a location within `base`, Safe_exception is raised.
        Resolving to base itself is also an error. *)
    let native_path_within_base crossplatform_path =
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
        resolved in

    try_lwt
      let {Feed.feed; Feed.id = _} = Feed.get_id impl in
      let open Recipe in
      (* Start all the downloads. The downloads happen in parallel, each returning
       * a future that will perform the extraction step. These futures are evaluated in sequence. *)
      let switch = Lwt_switch.create () in
      try_lwt
        let real_system = system#bypass_dryrun in    (* We really do extract to the temporary directory *)
        let downloads = retrieval_method |> List.map (function
          | DownloadStep {url; size; download_type = ArchiveDownload archive_info} ->
              (url, archive_info) |> download_archive ~switch ~may_use_mirror ?size ~feed (fun tmpfile ->
                let {extract; start_offset; mime_type; dest} = archive_info in
                let basedir =
                  match dest with
                  | None -> tmpdir
                  | Some dest ->
                      let basedir = native_path_within_base dest in
                      U.makedirs real_system basedir 0o755;
                      basedir in
                let request = `List [`String "unpack-archive"; `Assoc [
                  ("basedir", `String basedir);
                  ("tmpfile", `String tmpfile);
                  ("url", `String url);
                  ("extract", maybe extract);
                  ("dest", maybe dest);
                  ("start_offset", `Float (Int64.to_float start_offset));
                  ("mime_type", maybe mime_type);
                ]] in
                slave#invoke_async request (function
                  | `Null -> ()
                  | json -> raise_safe "Invalid JSON response '%s'" (Yojson.Basic.to_string json)
                )
              )
          | DownloadStep {url; size; download_type = FileDownload dest} ->
              url |> download_file ~switch ?size ~feed ~may_use_mirror:false (fun tmpfile ->
                let dest = native_path_within_base dest in
                U.makedirs real_system (Filename.dirname dest) 0o755;
                U.copy_file real_system tmpfile dest 0o644;
                slave#invoke_async (`List [`String "utime"; `String dest; `Float 0.0]) ignore
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
        lwt () = downloads |> Lwt_list.iter_s (fun fn ->
          lwt fn = fn in
          Lazy.force fn
        ) in
        let request = `List [
          `String "check-manifest-and-rename";
          `String (Stores.format_digest required_digest);
          `String tmpdir] in
        slave#invoke_async request (function
          | `List dry_run_paths ->
              need_rm_tmpdir := false;
              (* In --dry-run mode, the directories haven't actually been added, so we need to tell the
               * dryrun_system about them. *)
              if config.dry_run then (
                List.iter (fun name -> system#mkdir (Yojson.Basic.Util.to_string name) 0o755) dry_run_paths
              );
              `success
          | json -> raise_safe "Invalid JSON response '%s'" (Yojson.Basic.to_string json)
        )
      with ex ->
        lwt () = Lwt_switch.turn_off switch in
        match ex with
        | Aborted -> `aborted_by_user |> Lwt.return
        | Try_mirror msg -> `network_failure msg |> Lwt.return
        | _ -> raise ex
    finally
      try
        if !need_rm_tmpdir then (
          log_info "Removing temporary directory '%s'" tmpdir;
          U.rmtree ~even_if_locked:true config.system#bypass_dryrun tmpdir
        );
        Lwt.return ()
      with ex ->
        (* Don't mask the underlying error *)
        log_warning ~ex "Problem removing temporary directory";
        Lwt.return () in

  (** Download a 0install implementation and add it to a store *)
  let download_impl (impl, required_digest, retrieval_method) : unit Lwt.t =
    let download ~may_use_mirror recipe = download_impl_internal ~may_use_mirror impl required_digest recipe in
    try_lwt
      match_lwt download ~may_use_mirror:true retrieval_method with
      | `success -> Lwt.return ()
      | `aborted_by_user -> raise Aborted
      | `network_failure orig_msg ->
          match config.mirror with
          | None -> raise_safe "%s" orig_msg
          | Some mirror ->
              log_info "%s: trying implementation mirror at %s" orig_msg mirror;
              let mirror_download = get_impl_mirror_recipe mirror impl |? lazy (raise_safe "%s" orig_msg) in
              match_lwt download ~may_use_mirror:false mirror_download with
              | `aborted_by_user -> raise Aborted
              | `success -> Lwt.return ()
              | `network_failure mirror_msg ->
                  log_info "Error from mirror: %s" mirror_msg;
                  raise_safe "%s" orig_msg
    with Safe_exception _ as ex ->
      let {Feed.feed; Feed.id} = Feed.get_id impl in
      let version = Feed.get_attr_ex FeedAttr.version impl in
      reraise_with_context ex "... downloading implementation %s %s (id=%s)" feed version id in

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
            (* Choose the best digest algorithm we support *)
            if info.Feed.digests = [] then (
              Q.raise_elem "No digests at all! (so can't choose best) on " impl.Feed.qdom
            );
            let digest = Stores.best_digest info.Feed.digests in

            (* Pick the first retrieval method we understand *)
            match U.first_match info.Feed.retrieval_methods ~f:Recipe.parse_retrieval_method with
            | None -> raise_safe ("Implementation %s of interface %s cannot be downloaded " ^^
                                  "(no download locations given in feed!)") id feed
            | Some rm -> zi_impls := (impl, digest, rm) :: !zi_impls
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

    method downloader = downloader
  end
