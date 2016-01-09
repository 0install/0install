(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* A dummy web-server for unit-tests *)

open Support.Common
module U = Support.Utils

let re_http_get = Str.regexp "^GET \\([^ ]*\\) HTTP/.*"

let send_response ch code =
  Lwt_io.write ch (Printf.sprintf "HTTP/1.1 %d Code\r\n" code)

let send_header ch name value =
  Lwt_io.write ch (Printf.sprintf "%s: %s\r\n" name value)

let end_headers ch =
  Lwt_io.write ch "\r\n"

let send_error ch code msg =
  log_info "sending error: %d: %s" code msg;
  Lwt_io.write ch (Printf.sprintf "HTTP/1.1 %d %s\r\n" code msg) >> end_headers ch

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

let start_server system =
  let () = log_info "start_server" in
  let server_socket = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
  let request_log = ref [] in
  let expected = ref [] in

  let port =
    Lwt_unix.(setsockopt server_socket SO_REUSEADDR) true;
    Lwt_unix.set_close_on_exec server_socket;

    let rec find_port n =
      if n < 0 then raise_safe "Failed to find a free port (8000-8999) to bind to!";
      let port = 8000 + Random.int 1000 in
      try Lwt_unix.(bind server_socket (ADDR_INET (Unix.inet_addr_loopback, port))); port
      with Unix.Unix_error _ as ex ->
        log_info ~ex "Bind failed - port %d in use?" port;
        find_port (n - 1) in
    let port = find_port 100 in
    Lwt_unix.listen server_socket 5;
    port in

  let handle_request path to_client =
    let path = path |> Str.global_replace re_escaped_dot "." in
    log_info "Handling request for '%s'" path;

    request_log := path :: !request_log;

    let i = String.rindex path '/' in
    let leaf = U.string_tail path (i + 1) in

    match !expected with
    | [] -> raise_safe "Unexpected request for '%s' (nothing expected)" path
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
            send_response to_client 200 >>
            end_headers to_client >>
            send_body to_client "<key-lookup><item vote='good'>Approved for testing</item></key-lookup>"
        | `UnknownKey ->
            send_response to_client 200 >>
            end_headers to_client >>
            send_body to_client "<key-lookup/>"
        | `Give404 -> send_error to_client 404 ("Missing: " ^ leaf)
        | `Redirect redirect_target ->
            send_response to_client 302 >>
            send_header to_client "Location" redirect_target >>
            end_headers to_client >>
            send_body to_client "\
              <html>\n\
               <head>\n\
                <title>302 Found</title>\n\
               </head>\n\
               <body>\n\
                <h1>302 Found</h1>\n\
              </body>\n\
            </html>"
        | `ServeFile relpath ->
            lwt () = send_response to_client 200 >> end_headers to_client in
            let data = U.read_file system (Test_0install.feed_dir +/ relpath) in
            send_body to_client data;
        | `Serve ->
            lwt () = send_response to_client 200 >> end_headers to_client in
            let data = U.read_file system (Test_0install.feed_dir +/ leaf) in
            send_body to_client data;
        | `Chunked ->
            send_response to_client 200 >>
            send_header to_client "Transfer-Encoding" "chunked" >>
            end_headers to_client >>
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
    try_lwt
      while_lwt not !cancelled do
        lwt (connection, _client_addr) = Lwt_unix.accept server_socket in
        Lwt_unix.set_close_on_exec connection;
        try_lwt
          log_info "Got a connection!";
          let from_client = Lwt_io.of_fd ~mode:Lwt_io.input connection in
          lwt request = Lwt_io.read_line from_client in
          log_info "Got: %s" request;

          let done_headers = ref false in
          lwt () = while_lwt not !done_headers do
            lwt line = Lwt_io.read_line from_client in
            if trim line = "" then done_headers := true;
            Lwt.return ()
          done in

          if Str.string_match re_http_get request 0 then (
            let resource = Str.matched_group 1 request in
            let _host, path = Support.Urlparse.split_path resource in
            let to_client = Lwt_io.of_fd ~mode:Lwt_io.output connection in
            begin try_lwt handle_request path to_client
            with ex -> send_error to_client 501 (Printexc.to_string ex)
            end >> Lwt_io.flush to_client
          ) else (
            log_warning "Bad HTTP request '%s'" request;
            Lwt.return ();
          )
        finally
          log_info "Closing connection";
          Lwt_unix.close connection
      done
    with Lwt.Canceled -> Lwt.return ()
  in
  object
    method expect (requests:(string * response) list list) =
      if !expected = [] then
        expected := requests
      else
        raise_safe "Previous expected requests not used!"

    method port = port

    method terminate =
      log_info "Shutting down server...";
      cancelled := true;
      Lwt.cancel handler_thread;
      handler_thread >> Lwt_unix.close server_socket
  end

let with_server ?portable_base (fn:_ -> _ -> unit) =
  Fake_system.with_fake_config ?portable_base (fun (config, f) ->
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
