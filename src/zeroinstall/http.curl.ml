open Support
open Support.Common

let init = lazy (
  Curl.(global_init CURLINIT_GLOBALALL);
)

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
      if XString.starts_with (String.lowercase_ascii header) "location:" then (
        redirect := Some (XString.tail header 9 |> String.trim)
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
            `Unmodified  (* ocurl is missing CURLINFO_CONDITION_UNMET *)
          ) else (
            size |> if_some (fun expected ->
                let expected = Int64.to_float expected in
                if expected <> actual_size then
                  Safe_exn.failf "Downloaded archive has incorrect size.\n\
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

let post ~data url =
  let error_buffer = ref "" in

  let connection = Curl.init () in
  Curl.set_nosignal connection true;    (* Can't use DNS timeouts when multi-threaded *)
  Curl.set_failonerror connection true;
  if Support.Logging.will_log Support.Logging.Debug then Curl.set_verbose connection true;

  Curl.set_errorbuffer connection error_buffer;

  let output_buffer = Buffer.create 256 in
  Curl.set_writefunction connection (fun data ->
      Buffer.add_string output_buffer data;
      String.length data
    );

  Curl.set_url connection url;
  Curl.set_post connection true;
  Curl.set_postfields connection data;
  Curl.set_postfieldsize connection (String.length data);

  Lwt.finalize
    (fun () -> Curl_lwt.perform connection)
    (fun () -> Curl.cleanup connection; Lwt.return ())
  >|= function
  | Curl.CURLE_OK -> Ok (Buffer.contents output_buffer)
  | code ->
    let msg = Curl.strerror code in
    log_info "Curl error: %s\n%s" msg !error_buffer;
    Error (msg, !error_buffer)

module Connection = struct
  type t = Curl.t

  let create () =
    Lazy.force init;
    let t = Curl.init () in
    Curl.set_nosignal t true;    (* Can't use DNS timeouts when multi-threaded *)
    Curl.set_failonerror t true;
    Curl.set_followlocation t false;
    Curl.set_netrc t Curl.CURL_NETRC_OPTIONAL;
    t

  let release = Curl.cleanup

  let get = download_no_follow
end

let escape = Curl.escape

let variant = "libcurl (C)"
