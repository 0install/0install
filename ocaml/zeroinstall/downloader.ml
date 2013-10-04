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

let init_curl = lazy (
  (* from dx-ocaml *)
  Ssl.init ~thread_safe:true ();  (* Performs incantations to ensure thread-safety of OpenSSL *)
  Curl.(global_init CURLINIT_GLOBALALL)
)

let interceptor = ref None        (* (for unit-tests) *)

(** Download the contents of [url] into [ch]. *)
let download_no_follow ?size ?modification_time ch url =
  let error_buffer = ref "" in
  try
    let redirect = ref None in
    let check_header header =
      if U.starts_with header "Location:" then (
        redirect := Some (U.string_tail header 9 |> trim)
      );
      String.length header in

    let connection = Curl.init () in
    if Support.Logging.will_log Support.Logging.Debug then Curl.set_verbose connection true;
    Curl.set_nosignal connection true;    (* Can't use DNS timeouts when multi-threaded *)
    Curl.set_failonerror connection true;
    Curl.set_errorbuffer connection error_buffer;
    Curl.set_writefunction connection (fun data -> output_string ch data; String.length data);
    size |> if_some (Curl.set_maxfilesizelarge connection);
    modification_time |> if_some (fun modification_time ->
      Curl.set_timecondition connection Curl.TIMECOND_IFMODSINCE;
      Curl.set_timevalue connection (Int32.of_float modification_time);  (* Warning: 32-bit time *)
    );
    Curl.set_url connection url;
    Curl.set_headerfunction connection check_header;
    Curl.set_followlocation connection false;

    Curl.perform connection;

    let actual_size = Curl.get_sizedownload connection in

    Curl.cleanup connection;

    match !redirect with
    | Some target ->
        (* ocurl is missing CURLINFO_REDIRECT_URL, so we have to do this manually *)
        let target = Support.Urlparse.join_url url target in
        log_info "Redirect from '%s' to '%s'" url target;
        `redirect target |> Lwt.return
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
          `success |> Lwt.return
        )
  with Curl.CurlException _ as ex ->
    log_info ~ex "Curl error: %s" !error_buffer;
    let msg = Printf.sprintf "Error downloading '%s': %s" url !error_buffer in
    `network_failure msg |> Lwt.return

class downloader =
  let () = Lazy.force init_curl in

  object
    (** Download url to a new temporary file and return its name.
     * @param switch delete the temporary file when this is turned off
     * @param timeout a timer to start when the download starts (it will be queued first)
     * @param modification_time raise [Unmodified] if file hasn't changed since this time
     * @hint a tag to attach to the download (used by the GUI to associate downloads with feeds)
     *)
    method download ?switch ?modification_time ?timeout ?size ~hint url : download_result Lwt.t =
      log_info "Downloading URL '%s'... (for %s)" url hint;

      if not (List.exists (U.starts_with url) ["http://"; "https://"; "ftp://"]) then (
        raise_safe "Invalid scheme in URL '%s'" url
      );

      match !interceptor with
      | Some interceptor -> interceptor ?modification_time ?timeout ?size ~hint url 
      | None ->
          let tmpfile, ch = Filename.open_temp_file ~mode:[Open_binary] "0install-" "-download" in
          Lwt_switch.add_hook switch (fun () -> Unix.unlink tmpfile |> Lwt.return);

          timeout |> if_some Lwt_timeout.start;

          let rec loop redirs_left url =
            match_lwt download_no_follow ?modification_time ?size ch url with
            | `success ->
                close_out ch;
                `tmpfile tmpfile |> Lwt.return
            | `network_failure _ as failure ->
                close_out ch;
                Lwt.return failure
            | `redirect target ->
                Unix.ftruncate (Unix.descr_of_out_channel ch) 0;
                if target = url then raise_safe "Redirection loop getting '%s'" url
                else if redirs_left > 0 then loop (redirs_left - 1) target
                else raise_safe "Too many redirections (next: %s)" target in
          loop 10 url
  end
