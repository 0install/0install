(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* A dummy web-server for unit-tests *)

open Support
open Support.Common
module U = Support.Utils

let re_http_request = Str.regexp {|^\(GET\|POST\) \([^ ]*\) HTTP/.*|}

let send_response ch code =
  Lwt_io.write ch (Printf.sprintf "HTTP/1.1 %d Code\r\n" code)

let send_header ch name value =
  Lwt_io.write ch (Printf.sprintf "%s: %s\r\n" name value)

let end_headers ch =
  Lwt_io.write ch "\r\n"

let send_error ch code msg =
  log_info "sending error: %d: %s" code msg;
  Lwt_io.write ch (Printf.sprintf "HTTP/1.1 %d %s\r\n" code msg) >>= fun () -> end_headers ch

let send_body ch data =
  Lwt_io.write ch data

type response =
  [ `Serve
  | `ServeFile of filepath
  | `Chunked
  | `AcceptKey
  | `UnknownKey
  | `Redirect of string
  | `Unexpected
  | `Give404 ]

(* Old versions of Curl escape dots *)
let re_escaped_dot = Str.regexp_string "%2E"

let ignore_cancelled f =
  Lwt.catch f
    (function
      | Lwt.Canceled -> Lwt.return ()
      | ex -> Lwt.fail ex
    )

let read_headers from_client =
  let rec aux acc =
    Lwt_io.read_line from_client >>= fun line ->
    if String.trim line = "" then Lwt.return acc
    else (
      let key, value = XString.(split_pair_safe re_colon) line in
      let key = String.trim key |> String.lowercase_ascii in
      let value = String.trim value in
      aux (XString.Map.add key value acc)
    )
  in
  aux XString.Map.empty

let re_3a = Str.regexp_string "%3A"

let start_server system =
  let () = log_info "start_server" in
  let server_socket = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
  let request_log = ref [] in
  let expected = ref [] in

  let port =
    Lwt_unix.(setsockopt server_socket SO_REUSEADDR) true;
    Lwt_unix.set_close_on_exec server_socket;

    let rec find_port n =
      if n < 0 then Safe_exn.failf "Failed to find a free port (8000-8999) to bind to!";
      let port = 8000 + Random.int 1000 in
      try Unix.(bind (Lwt_unix.unix_file_descr server_socket) (ADDR_INET (Unix.inet_addr_loopback, port))); port
      with Unix.Unix_error _ as ex ->
        log_info ~ex "Bind failed - port %d in use?" port;
        find_port (n - 1) in
    let port = find_port 100 in
    Lwt_unix.listen server_socket 5;
    port in

  let handle_request path to_client =
    let path = path
               |> Str.global_replace re_escaped_dot "."
               |> Str.global_replace re_3a ":" (* Curl escapes :, but Uri doesn't - accept either *)
    in
    log_info "Handling request for '%s'" path;

    request_log := path :: !request_log;

    let i = String.rindex path '/' in
    let leaf = XString.tail path (i + 1) in

    match !expected with
    | [] -> Safe_exn.failf "Unexpected request for '%s' (nothing expected)" path
    | next_step :: rest ->
        let response, next_step =
          try (List.assoc path next_step, List.remove_assoc path next_step)
          with Not_found ->
            try (List.assoc leaf next_step, List.remove_assoc leaf next_step)
            with Not_found -> (`Unexpected, next_step) in
        expected :=
          if next_step = [] then rest
          else next_step :: rest;

        match response with
        | `AcceptKey ->
            send_response to_client 200 >>= fun () ->
            end_headers to_client >>= fun () ->
            send_body to_client "<key-lookup><item vote='good'>Approved for testing</item></key-lookup>"
        | `UnknownKey ->
            send_response to_client 200 >>= fun () ->
            end_headers to_client >>= fun () ->
            send_body to_client "<key-lookup/>"
        | `Give404 -> send_error to_client 404 ("Missing: " ^ leaf)
        | `Redirect redirect_target ->
            send_response to_client 302 >>= fun () ->
            send_header to_client "LocatioN" redirect_target >>= fun () ->
            let msg = "<html>\n\
                         <head>\n\
                          <title>302 Found</title>\n\
                         </head>\n\
                         <body>\n\
                          <h1>302 Found</h1>\n\
                        </body>\n\
                      </html>"
            in
            let len = string_of_int (String.length msg) in
            send_header to_client "Content-Length" len >>= fun () ->
            end_headers to_client >>= fun () ->
            send_body to_client msg
        | `ServeFile relpath ->
            send_response to_client 200 >>= fun () ->
            end_headers to_client >>= fun () ->
            let data = U.read_file system (Fake_system.test_data relpath) in
            send_body to_client data;
        | `Serve ->
            send_response to_client 200 >>= fun () ->
            end_headers to_client >>= fun () ->
            let data = U.read_file system (Fake_system.test_data leaf) in
            send_body to_client data;
        | `Chunked ->
            send_response to_client 200 >>= fun () ->
            send_header to_client "Transfer-Encoding" "chunked" >>= fun () ->
            end_headers to_client >>= fun () ->
            send_body to_client "a\r\n\
                                 hello worl\r\n\
                                 1\r\n\
                                 d\r\n"
        | `Unexpected ->
            let options = String.concat "|" (List.map fst next_step) in
            send_error to_client 404 (Printf.sprintf "Expected %s; got %s" options (String.concat "," !request_log))
    in

  let cancelled = ref false in (* If we're unlucky (race), Lwt.cancel might not work; this is a backup system *)
  let handler_thread =
    let rec loop () =
      if !cancelled then Lwt.return ()
      else (
        Lwt_unix.accept server_socket >>= fun (connection, _client_addr) ->
        Lwt_unix.set_close_on_exec connection;
        Lwt.finalize
          (fun () ->
             log_info "Got a connection!";
             let from_client = Lwt_io.of_fd ~mode:Lwt_io.input connection in
             Lwt_io.read_line from_client >>= fun request ->
             log_info "Got: %s" request;
             read_headers from_client >>= fun headers ->
             begin
               match XString.Map.find_opt "content-length" headers with
               | None -> Lwt.return ()
               | Some size ->
                 let size = int_of_string size in
                 Lwt_io.read ~count:size from_client >|= fun body ->
                 log_info "Got body %S" body
             end >>= fun () ->
             if Str.string_match re_http_request request 0 then (
               let resource = Str.matched_group 2 request in
               let _host, path = Support.Urlparse.split_path resource in
               let to_client = Lwt_io.of_fd ~mode:Lwt_io.output connection in
               Lwt.catch
                 (fun () -> handle_request path to_client)
                 (fun ex -> send_error to_client 501 (Printexc.to_string ex))
               >>= fun () ->
               Lwt_io.flush to_client
             ) else (
               log_warning "Bad HTTP request '%s'" request;
               Lwt.return ();
             )
          )
          (fun () ->
             log_info "Closing connection";
             Lwt_unix.close connection
          ) >>= loop
      ) in
      ignore_cancelled loop
    in
  object
    method expect (requests:(string * response) list list) =
      if !expected = [] then
        expected := requests
      else
        Safe_exn.failf "Previous expected requests not used!"

    method port = port

    method terminate =
      log_info "Shutting down server...";
      cancelled := true;
      Lwt.cancel handler_thread;
      handler_thread >>= fun () -> Lwt_unix.close server_socket
  end

let with_server ?portable_base (fn:_ -> _ -> unit) =
  Fake_system.with_fake_config ?portable_base (fun (config, f) ->
    OUnit.skip_if on_windows "Fails with Unix.EAFNOSUPPORT";
    Support.Logging.threshold := Support.Logging.Info;  (* Otherwise, curl prints everything *)

    let config = {config with Zeroinstall.General.key_info_server = Some "http://localhost:3333/key-info"} in
    Zeroinstall.Config.save_config config;
    let agent = Fake_gpg_agent.run f#tmpdir in

    U.finally_do
      (fun s ->
        Lwt.cancel agent;
        Lwt_main.run s#terminate;
        Unix.putenv "http_proxy" "localhost:8000"
      )
      (start_server config.Zeroinstall.General.system)
      (fun server ->
        Unix.putenv "http_proxy" ("localhost:" ^ (string_of_int server#port));
        fn (config, f) server; server#expect [];
      )
  )
