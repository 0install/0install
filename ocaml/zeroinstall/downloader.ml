(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Low-level download interface *)

open Support.Common

module U = Support.Utils

type progress = (Int64.t * Int64.t option * bool) Lwt_react.signal

type download = {
  cancel : unit -> unit Lwt.t;
  url : string;
  progress : progress;    (* Must keep a reference to this; if it gets GC'd then updates stop. *)
  hint : string option;
}

type download_result =
 [ `Aborted_by_user
 | `Network_failure of string
 | `Tmpfile of Support.Common.filepath ]

exception Unmodified

let is_in_progress dl =
  let (_, _, finished) = Lwt_react.S.value dl.progress in
  not finished

let init = lazy (
  Curl.(global_init CURLINIT_GLOBALALL);
)

let interceptor = ref None        (* (for unit-tests) *)

let is_redirect connection =
  let code = Curl.get_httpcode connection in
  code >= 300 && code < 400

(** Download the contents of [url] into [ch].
 * This runs in a separate (either Lwt or native) thread. *)
let download_no_follow ~cancelled ?size ?modification_time ?(start_offset=Int64.zero) ~progress connection ch url =
  let skip_bytes = ref (Int64.to_int start_offset) in
  let error_buffer = ref "" in
  Lwt.catch (fun () ->
    let redirect = ref None in
    let check_header header =
      if U.starts_with header "Location:" then (
        redirect := Some (U.string_tail header 9 |> String.trim)
      );
      String.length header in

    if Support.Logging.will_log Support.Logging.Debug then Curl.set_verbose connection true;
    Curl.set_errorbuffer connection error_buffer;
    Curl.set_writefunction connection (fun data ->
      if !cancelled then 0
      else (
        try
          let l = String.length data in
          if !skip_bytes >= l then (
            skip_bytes := !skip_bytes - l
          ) else (
            output ch (Bytes.unsafe_of_string data) !skip_bytes (l - !skip_bytes);
            skip_bytes := 0
          );
          l
        with ex ->
          log_warning ~ex "Failed to write download data to temporary file";
          error_buffer := !error_buffer ^ Printexc.to_string ex;
          0
      )
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
    Curl.set_useragent connection ("0install/" ^ About.version);
    Curl.set_headerfunction connection check_header;
    Curl.set_progressfunction connection (fun dltotal dlnow _ultotal _ulnow ->
        if !cancelled then true    (* Don't override the finished=true signal *)
        else (
          let dlnow = Int64.of_float dlnow in
          begin match size with
            | Some _ -> progress (dlnow, size, false)
            | None ->
              let total = if dltotal = 0.0 then None else Some (Int64.of_float dltotal) in
              progress (dlnow, total, false) end;
          false  (* (continue download) *)
        )
    );
    Curl.set_noprogress connection false; (* progress = true *)

    Curl_lwt.perform connection >|= fun result ->
    (* Check for redirect header first because for large redirect bodies we
       may get a size-exceeded error rather than CURLE_OK. *)
    match !redirect with
    | Some target when is_redirect connection ->
      (* ocurl is missing CURLINFO_REDIRECT_URL, so we have to do this manually *)
      let target = Support.Urlparse.join_url url target in
      log_info "Redirect from '%s' to '%s'" url target;
      `Redirect target
    | _ ->
      match result with
      | Curl.CURLE_OK ->
        begin
          let actual_size = Curl.get_sizedownload connection in

          (* Curl.cleanup connection; - leave it open for the next request *)

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
            log_info "Download '%s' completed successfully (%.0f bytes)" url actual_size;
            `Success
          )
        end
      | code -> raise Curl.(CurlException (code, errno code, strerror code))
  )
  (function
  | Curl.CurlException _ as ex ->
      if !cancelled then Lwt.return `Aborted_by_user
      else (
        log_info ~ex "Curl error: %s" !error_buffer;
        let msg = Printf.sprintf "Error downloading '%s': %s" url !error_buffer in
        Lwt.return (`Network_failure msg)
      )
  | ex -> raise ex
  )

module Site = struct
  type t = {
    max_downloads_per_site : int;
    connections : Curl.t option ref Queue.t;
    pool : Curl.t option ref Lwt_pool.t;
  }

  (** Rate-limits downloads within a site.
   * [domain] is e.g. "http://site:port" - the URL before the path *)
  let make ~max_downloads_per_site =
    let connections = Queue.create () in
    let create_connection () =
      let connection = Curl.init () in
      Curl.set_nosignal connection true;    (* Can't use DNS timeouts when multi-threaded *)
      Curl.set_failonerror connection true;
      Curl.set_followlocation connection false;
      Curl.set_netrc connection Curl.CURL_NETRC_OPTIONAL;
      let r = ref (Some connection) in
      Queue.add r connections;
      Lwt.return r in
    let validate c = Lwt.return (!c <> None) in
    let pool = Lwt_pool.create max_downloads_per_site create_connection ~validate in
    {
      max_downloads_per_site;
      connections;
      pool;
    }

  let schedule_download t ~cancelled ?if_slow ?size ?modification_time ?start_offset ~progress ch url =
    log_debug "Scheduling download of %s" url;
    if not (List.exists (U.starts_with url) ["http://"; "https://"; "ftp://"]) then (
      raise_safe "Invalid scheme in URL '%s'" url
    );

    Lwt_pool.use t.pool (fun r ->
      match !r with
      | None -> failwith "Attempt to use a freed connection!"
      | Some connection ->
          match !interceptor with
          | Some interceptor ->
              interceptor ?if_slow ?size ?modification_time ch url
          | None ->
              let timeout = if_slow |> pipe_some (fun if_slow ->
                let timeout = Lwt_timeout.create 5 (fun () -> Lazy.force if_slow) in
                Lwt_timeout.start timeout;
                Some timeout;
              ) in

              let download () = download_no_follow ~cancelled ?modification_time ?size ?start_offset ~progress connection ch url in

              Lwt.finalize download
                (fun () ->
                   timeout |> if_some Lwt_timeout.stop;
                   Lwt.return ()
                )
    )

  (** Clean up all Curl connections. Call this before discarding the site. *)
  let release t =
    let cleanup r =
      match !r with
      | None -> log_warning "Attempt to cleanup an already-cleaned connection!"
      | Some c -> Curl.cleanup c; r := None in
    Queue.iter cleanup t.connections;
    Queue.clear t.connections
end

type monitor = download -> unit

type t = {
  monitor : monitor;
  sites : (string, Site.t) Hashtbl.t;
  max_downloads_per_site : int;
}

(** Empty the file and reset the FD to the start.
 * On Windows, we have to close and reopen the file to do this. *)
let truncate_to_empty tmpfile ch =
  flush !ch;
  if Sys.os_type = "Win32" then (
    close_out !ch;
    ch := open_out_gen [Open_wronly; Open_trunc; Open_binary] 0o700 tmpfile;
    Unix.set_close_on_exec (Unix.descr_of_out_channel !ch);
  ) else (
    Unix.ftruncate (Unix.descr_of_out_channel !ch) 0;
    seek_out !ch 0
  )

(** A temporary file that will be deleted when the switch is turned off. *)
let tmpfile_with_switch ?switch ~prefix ~suffix =
  let tmpfile, ch = Filename.open_temp_file ~mode:[Open_binary] prefix suffix in
  Unix.set_close_on_exec (Unix.descr_of_out_channel ch);
  let ch = ref ch in
  Lwt_switch.add_hook switch (fun () ->
    begin try
      close_out !ch;         (* For Windows: ensure file is closed before unlinking *)
      Unix.unlink tmpfile
    with ex ->
      log_warning ~ex "Failed to delete temporary file for download '%s'" tmpfile
    end;
    Lwt.return ()
  );
  tmpfile, ch

let get_site t domain =
  try Hashtbl.find t.sites domain
  with Not_found ->
    let site = Site.make ~max_downloads_per_site:t.max_downloads_per_site in
    Hashtbl.add t.sites domain site;
    site

let network_failure fmt =
  fmt |> Format.kasprintf @@ fun msg -> Lwt.return (`Network_failure msg)

let catch_cancel task =
  Lwt.catch (fun () -> task)
    (function
      | Lwt.Canceled -> Lwt.return `Aborted_by_user
      | ex -> Lwt.fail ex
    )

let download t ~switch ?modification_time ?if_slow ?size ?start_offset ?hint url =
  let hint = hint |> pipe_some (fun feed -> Some (Feed_url.format_url feed)) in
  log_debug "Download URL '%s'... (for %s)" url (default "no feed" hint);
  let progress, set_progress = Lwt_react.S.create (Int64.zero, size, false) in
  let cancelled = ref false in
  let tmpfile, ch = tmpfile_with_switch ~switch ~prefix:"0install-" ~suffix:"-download" in
  let rec loop redirs_left url =
    let domain, _ = Support.Urlparse.split_path url in
    let site = get_site t domain in
    Site.schedule_download site ~cancelled ?if_slow ?size ?modification_time ?start_offset ~progress:set_progress !ch url >>= function
    | `Success ->
        close_out !ch;
        `Tmpfile tmpfile |> Lwt.return
    | (`Network_failure _ | `Aborted_by_user) as result ->
        close_out !ch;
        Lwt.return result
    | `Redirect target ->
        truncate_to_empty tmpfile ch;
        if target = url then network_failure "Redirection loop getting '%s'" url
        else if redirs_left > 0 then loop (redirs_left - 1) target
        else network_failure "Too many redirections (next: %s)" target in
  (* Cancelling:
   * ocurl is missing OPENSOCKETFUNCTION, but we can get close by setting a flag so that it
   * aborts on the next write. In any case, we don't wait for the thread exit, as it may be
   * blocked on a DNS lookup, etc. *)
  let task, waker = Lwt.task () in
  let cancel () =
    log_info "Cancelling download %s" url;
    cancelled := true;
    Lwt.cancel task;
    Lwt.return () in
  let task = catch_cancel task in
  t.monitor {cancel; url; progress; hint};
  (* Do the download *)
  U.async (fun () ->
    Lwt.catch
      (fun () -> loop 10 url >|= Lwt.wakeup waker)
      (fun ex ->
         log_info ~ex "Download failed";
         close_out !ch;
         Lwt.wakeup_exn waker ex; Lwt.return ()
      )
  );
  (* Stop progress indicator when done *)
  Lwt.finalize
    (fun () -> task)
    (fun () ->
      let (sofar, total, _) = Lwt_react.S.value progress in
      set_progress (sofar, total, true);
      Lwt.return ()
    )

let download_if_unmodified t ~switch ?modification_time ?if_slow ?size ?start_offset ?hint url =
  Lwt.catch
    (fun () -> download t ~switch ?modification_time ?if_slow ?size ?start_offset ?hint url)
    (function
      | Unmodified -> Lwt.return `Unmodified
      | ex -> Lwt.fail ex
    )

let download = download ?modification_time:None

class type download_pool =
  object
    method with_monitor : monitor -> t
    method release : unit
  end

let make_pool ~max_downloads_per_site : download_pool =
  let () = Lazy.force init in
  let sites = Hashtbl.create 10 in

  object
    method with_monitor monitor = { monitor; sites; max_downloads_per_site }

    method release =
      Hashtbl.iter (fun _ -> Site.release) sites;
      Hashtbl.clear sites
  end
