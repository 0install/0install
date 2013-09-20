(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
open Support.Common

module Q = Support.Qdom

type try_mirror_case = [ `problem of string ]
type non_mirror_case = [ `ok of Q.element | `no_trusted_keys | `replay_attack of string | `aborted_by_user ]

type fetch_feed_response =
  [ `update of (Q.element * fetch_feed_response Lwt.t option)  (* Use this version (but a better version may come soon) *)
  | `aborted_by_user        (* Abort silently (no need to notify the user) *)
  | `problem of (string * fetch_feed_response Lwt.t option)    (* Report a problem (but may still succeed later) *)
  | `no_update ]            (* Use the previous version *)

let get_response = function
  | `ok result -> `update (result, None)
  | `aborted_by_user -> `aborted_by_user
  | `no_trusted_keys ->         (* Don't bother trying the mirror if we have a trust problem *)
      `problem ("Not signed with a trusted key", None)
  | `replay_attack msg ->       (* Don't bother trying the mirror if we have a replay attack *)
      `problem (msg, None)

let last_ticket = ref 0
let timeout_tickets = ref StringMap.empty
let take_ticket timeout =
  last_ticket := !last_ticket + 1;
  let ticket = string_of_int !last_ticket in
  timeout_tickets := StringMap.add ticket timeout !timeout_tickets;
  ticket

class fetcher config (slave:Python.slave) =
  let () =
    Python.register_handler "start-timeout" (function
      | [`String ticket] ->
          let timeout = StringMap.find ticket !timeout_tickets in
          timeout_tickets := StringMap.remove ticket !timeout_tickets;
          Lwt_timeout.start timeout;
          Lwt.return `Null
      | json -> raise_safe "start-timeout: invalid request: %s" (Yojson.Basic.to_string (`List json))
    ) in

  (* Try to download this feed, either from the mirror (if [use_mirror] is true) or from the primary if not.
   * If present, start [timeout_waker] when the download actually starts (time spent queuing doesn't count). *)
  let download_and_import_feed_internal ?timeout feed ~use_mirror =
    let `remote_feed feed_url = feed in

    let timeout_ticket =
      match timeout with
      | None -> `Null
      | Some timeout -> `String (take_ticket timeout) in

    let request = `List [
      `String "download-and-import-feed";
      `String feed_url;
      `Bool use_mirror;
      timeout_ticket
    ] in

    try_lwt
      slave#invoke_async request (function
        | `List [`String "success"; `String xml] ->
            let cache_path = Feed_cache.get_save_cache_path config feed in
            let root = `String (0, xml) |> Xmlm.make_input |> Q.parse_input (Some cache_path) in
            `ok root
        | `String "aborted-by-user" -> `aborted_by_user
        | `List [`String "replay-attack"; `String msg] -> `replay_attack msg
        | `String "no-trusted-keys" -> `no_trusted_keys
        | _ -> raise_safe "Invalid JSON response"
      )
    with Safe_exception (msg, _) ->
      `problem msg |> Lwt.return
  in

  (* The primary failed (already reported). Wait for the mirror. *)
  let wait_for_mirror mirror =
    match_lwt mirror with
    (* We already warned; no need to raise an exception too, as the mirror download succeeded. *)
    | `ok result -> `update (result, None) |> Lwt.return
    | `aborted_by_user -> `aborted_by_user |> Lwt.return
    | `replay_attack msg ->
        log_info "Version from mirror is older than cached version; ignoring it (%s)" msg;
        Lwt.return `no_update
    | `no_trusted_keys ->
        Lwt.return `no_update
    | `problem msg ->
        log_info "Mirror download failed: %s" msg;
        Lwt.return `no_update in

  let wait_for_primary primary : _ Lwt.t =
    (* Wait for the primary (we're already got a response or failure from the mirror) *)
    match_lwt primary with
    | #non_mirror_case as result -> get_response result |> Lwt.return
    | `problem msg -> `problem (msg, None) |> Lwt.return in

  object
    method download_and_import_feed (feed : [`remote_feed of feed_url]) : fetch_feed_response Lwt.t =
      let `remote_feed feed_url = feed in
      log_debug "download_and_import_feed %s" feed_url;

      if not config.dry_run then (
        Feed_cache.mark_as_checking config feed
      );
      
      let timeout_task, timeout_waker = Lwt.wait () in
      let timeout = Lwt_timeout.create 5 (fun () -> Lwt.wakeup timeout_waker `timeout) in

      let primary = download_and_import_feed_internal feed ~timeout ~use_mirror:false in
      let do_mirror_download () =
        download_and_import_feed_internal feed ~use_mirror:true in

      (* Download just the upstream feed, unless it takes too long... *)
      match_lwt Lwt.pick [primary; timeout_task] with
      (* Downloaded feed within 5 seconds *)
      | #non_mirror_case as result -> get_response result |> Lwt.return
      | `problem msg ->
          let mirror = do_mirror_download () in
          `problem (msg, Some (wait_for_mirror mirror)) |> Lwt.return
      | `timeout ->
          (* OK, maybe it's just being slow... *)
          log_info "Feed download from %s is taking a long time." feed_url;

          (* Start downloading from mirror... *)
          let mirror = do_mirror_download () in

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
              | `replay_attack msg ->
                  log_info "Version from mirror is older than cached version; ignoring it (%s)" msg;
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
                  get_response result |> Lwt.return
              | `problem msg ->
                  `problem (msg, Some (wait_for_mirror mirror)) |> Lwt.return
          )

    (** Ensure all selections are cached, downloading any that are missing.
        If [distro] is given then distribution packages are also installed, otherwise
        they are ignored. *)
    method download_selections ?distro sels : [ `success | `aborted_by_user ] Lwt.t =
      if Selections.get_unavailable_selections config ?distro sels <> [] then (
        let opts = `Assoc [
          ("include-packages", `Bool (distro <> None));
        ] in

        let request : Yojson.Basic.json = `List [`String "download-selections"; opts] in

        lwt result =
          slave#invoke_async ~xml:sels request (function
            | `List dry_run_paths -> `success (List.map Yojson.Basic.Util.to_string dry_run_paths)
            | `String "aborted-by-user" -> `aborted_by_user
            | json -> raise_safe "Invalid JSON response '%s'" (Yojson.Basic.to_string json)
          ) in

        match result with
        | `aborted_by_user -> Lwt.return `aborted_by_user
        | `success dry_run_paths ->
            (* In --dry-run mode, the directories haven't actually been added, so we need to tell the
             * dryrun_system about them. *)
            if config.dry_run then (
              List.iter (fun name -> config.system#mkdir name 0o755) dry_run_paths
            );
            Lwt.return `success
      ) else (
        Lwt.return `success
      )
  end
