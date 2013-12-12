(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Low-level download interface *)

open Support.Common

module U = Support.Utils

type download_result =
 [ `aborted_by_user
 | `network_failure of string
 | `tmpfile of Support.Common.filepath ]

exception Unmodified

let init = lazy (
  Lwt_preemptive.init 0 100 (log_warning "%s");
  (* from dx-ocaml *)
  Ssl.init ~thread_safe:true ();  (* Performs incantations to ensure thread-safety of OpenSSL *)
  Curl.(global_init CURLINIT_GLOBALALL);
)

let interceptor = ref None        (* (for unit-tests) *)

(** Download the contents of [url] into [ch].
 * This runs in a separate (real) thread. *)
let download_no_follow ?size ?modification_time ?(start_offset=Int64.zero) ~progress connection ch url =
  let skip_bytes = ref (Int64.to_int start_offset) in
  let error_buffer = ref "" in
  try
    let redirect = ref None in
    let check_header header =
      if U.starts_with header "Location:" then (
        redirect := Some (U.string_tail header 9 |> trim)
      );
      String.length header in

    if Support.Logging.will_log Support.Logging.Debug then Curl.set_verbose connection true;
    Curl.set_errorbuffer connection error_buffer;
    Curl.set_writefunction connection (fun data ->
      try
        let l = String.length data in
        if !skip_bytes >= l then (
          skip_bytes := !skip_bytes - l
        ) else (
          output ch data !skip_bytes (l - !skip_bytes);
          skip_bytes := 0
        );
        l
      with ex ->
        (* (probably because we cancelled the download) *)
        log_info ~ex "Failed to write download data to temporary file";
        error_buffer := !error_buffer ^ Printexc.to_string ex;
        0
    );
    Curl.set_maxfilesizelarge connection (default Int64.zero size);

    begin match modification_time with
    | Some modification_time ->
        Curl.set_timecondition connection Curl.TIMECOND_IFMODSINCE;
        Curl.set_timevalue connection (Int32.of_float modification_time);  (* Warning: 32-bit time *)
    | None ->
        (* ocurl won't let us unset timecondition, but at least we can make sure it never happens *)
        Curl.set_timevalue connection (Int32.zero) end;

    Curl.set_url connection url;
    Curl.set_headerfunction connection check_header;
    Curl.set_progressfunction connection (fun dltotal dlnow _ultotal _ulnow ->
      Support.Lwt_preemptive_copy.run_in_main (fun () ->
        let dlnow = Int64.of_float dlnow in
        begin match size with
        | None -> progress (dlnow, if dltotal = 0.0 then None else Some (Int64.of_float dltotal));
        | Some _ -> progress (dlnow, size) end;
        Lwt.return false  (* (continue download) *)
      )
    );
    Curl.set_noprogress connection false; (* progress = true *)

    Curl.perform connection;

    let actual_size = Curl.get_sizedownload connection in

    (* Curl.cleanup connection; - leave it open for the next request *)

    match !redirect with
    | Some target ->
        (* ocurl is missing CURLINFO_REDIRECT_URL, so we have to do this manually *)
        let target = Support.Urlparse.join_url url target in
        log_info "Redirect from '%s' to '%s'" url target;
        `redirect target
    | None ->
        if modification_time <> None && actual_size = 0.0 then (
          raise Unmodified  (* ocurl is missing CURLINFO_CONDITION_UNMET *)
        ) else (
          size |> if_some (fun expected ->
            let expected = Int64.to_float expected in
            if expected <> actual_size then
              raise_safe "Downloaded archive has incorrect size.\n\
                          URL: %s\n\
                          Expected: %.0f bytes\n\
                          Received: %.0f bytes" url expected actual_size
          );
          `success
        )
  with Curl.CurlException _ as ex ->
    log_info ~ex "Curl error: %s" !error_buffer;
    let msg = Printf.sprintf "Error downloading '%s': %s" url !error_buffer in
    `network_failure msg

(** Rate-limits downloads within a site.
 * [domain] is e.g. "http://site:port" - the URL before the path *)
let make_site max_downloads_per_site =
  let create_connection () =
    let connection = Curl.init () in
    Curl.set_nosignal connection true;    (* Can't use DNS timeouts when multi-threaded *)
    Curl.set_failonerror connection true;
    Curl.set_followlocation connection false;
    Lwt.return connection in

  let pool = Lwt_pool.create max_downloads_per_site create_connection in

  object
    method schedule_download ?if_slow ?size ?modification_time ?start_offset ~progress ch url =
      log_debug "Scheduling download of %s" url;
      if not (List.exists (U.starts_with url) ["http://"; "https://"; "ftp://"]) then (
        raise_safe "Invalid scheme in URL '%s'" url
      );

      Lwt_pool.use pool (fun connection ->
        match !interceptor with
        | Some interceptor ->
            interceptor ?if_slow ?size ?modification_time ch url
        | None ->
            let timeout = if_slow |> pipe_some (fun if_slow ->
              let timeout = Lwt_timeout.create 5 (fun () -> Lazy.force if_slow) in
              Lwt_timeout.start timeout;
              Some timeout;
            ) in

            let download () = download_no_follow ?modification_time ?size ?start_offset ~progress connection ch url in

            try_lwt
              Lwt_preemptive.detach download ()
            finally
              timeout |> if_some Lwt_timeout.stop;
              Lwt.return ()
      )
  end

class downloader (reporter:Ui.ui_handler Lazy.t) ~max_downloads_per_site =
  let () = Lazy.force init in
  let sites = Hashtbl.create 10 in

  object
    (** Download url to a new temporary file and return its name.
     * @param switch delete the temporary file when this is turned off
     * @param if_slow is forced if the download is taking a long time (excluding queuing time)
     * @param modification_time raise [Unmodified] if file hasn't changed since this time
     * @hint a tag to attach to the download (used by the GUI to associate downloads with feeds)
     *)
    method download : 'a. switch:Lwt_switch.t -> ?modification_time:float -> ?if_slow:(unit Lazy.t) ->
                      ?size:Int64.t -> ?start_offset:Int64.t -> ?hint:([< Feed_url.parsed_feed_url] as 'a) ->
                      string -> download_result Lwt.t =
                      fun ~switch ?modification_time ?if_slow ?size ?start_offset ?hint url ->
      let hint = hint |> pipe_some (fun feed -> Some (Feed_url.format_url feed)) in
      log_debug "Download URL '%s'... (for %s)" url (default "no feed" hint);

      let progress, set_progress = Lwt_react.S.create (Int64.zero, size) in     (* So far / total *)

      let tmpfile, ch = Filename.open_temp_file ~mode:[Open_binary] "0install-" "-download" in
      Lwt_switch.add_hook (Some switch) (fun () -> Unix.unlink tmpfile |> Lwt.return);

      let rec loop redirs_left url =
        let site =
          let domain, _ = Support.Urlparse.split_path url in
          try Hashtbl.find sites domain
          with Not_found ->
            let site = make_site max_downloads_per_site in
            Hashtbl.add sites domain site;
            site in
        match_lwt site#schedule_download ?if_slow ?size ?modification_time ?start_offset ~progress:set_progress ch url with
        | `success ->
            close_out ch;
            `tmpfile tmpfile |> Lwt.return
        | `network_failure _ as failure ->
            close_out ch;
            Lwt.return failure
        | `redirect target ->
            flush ch;
            Unix.ftruncate (Unix.descr_of_out_channel ch) 0;
            seek_out ch 0;
            if target = url then raise_safe "Redirection loop getting '%s'" url
            else if redirs_left > 0 then loop (redirs_left - 1) target
            else raise_safe "Too many redirections (next: %s)" target in

      let reporter = Lazy.force reporter in

      (* Cancelling:
       * ocurl is missing OPENSOCKETFUNCTION, but we can get close by closing tmpfile so that it
       * aborts on the next write. In any case, we don't wait for the thread exit, as it may be
       * blocked on a DNS lookup, etc. *)
      let task, waker = Lwt.task () in
      Lwt.on_cancel task (fun () -> close_out ch);
      let cancel () = Lwt.cancel task; Lwt.return () in
      let dl = Ui.({cancel; url; progress; hint}) in
      lwt () = reporter#start_monitoring ~id:tmpfile dl in

      Python.async (fun () ->
        try_lwt
          lwt result = loop 10 url in
          Lwt.wakeup waker result;
          Lwt.return ()
        with ex ->
          Lwt.wakeup_exn waker ex; Lwt.return ()
      );

      try_lwt task
      with Lwt.Canceled -> `aborted_by_user |> Lwt.return
      finally reporter#stop_monitoring ~id:tmpfile
  end
