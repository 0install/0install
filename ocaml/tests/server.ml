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
  [ `File
  | `Chunked
  | `Give404 ]

let start_server system =
  let () = log_info "start_server" in
  let server_socket = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
  let request_log = ref [] in
  let expected = ref [] in

  let handle_request path to_client =
    log_info "Handling request for '%s'" path;

    request_log := path :: !request_log;

    if U.starts_with path "/redirect/" then (
      let i = String.index_from path 1 '/' in
      let redirect_target = U.string_tail path i in
      send_response to_client 302 >>
      send_header to_client "Location" redirect_target >>
      end_headers to_client
    ) else (
      let i = String.rindex path '/' in
      let leaf = U.string_tail path (i + 1) in

      match !expected with
      | [] -> raise_safe "Unexpected request for '%s' (nothing expected)" path
      | next_step :: rest ->
(*
          resp = acceptable.get(parsed.path, None) or \
                 acceptable.get(leaf, None) or \
                 acceptable.get('*', None)
*)
          let response, next_step =
            try (List.assoc path next_step, List.remove_assoc path next_step)
            with Not_found ->
              try (List.assoc leaf next_step, List.remove_assoc leaf next_step)
              with Not_found -> (`Unexpected, next_step) in
          expected :=
            if next_step = [] then rest
            else next_step :: rest;

          let leaf =
            if U.starts_with path "/0mirror/search/?q=" then (
              let q = U.string_tail path 19 in
              "search-" ^ q ^ ".xml"
            ) else if leaf = "latest.xml" then (
              (* (don't use a symlink as they don't work on Windows) *)
              "Hello.xml"
            ) else if path = "/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz" then (
              "HelloWorld.tgz"
            ) else if path = "/0mirror/feeds/http/example.com:8000/Hello.xml/impl/sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" then (
              "HelloWorld.tar.bz2"
            ) else leaf in

          if U.starts_with path "/key-info/" then (
            send_response to_client 200 >>
            end_headers to_client >>
            send_body to_client "<key-lookup><item vote='good'>Approved for testing</item></key-lookup>"
          ) else (
            match response with
            | `Give404 -> send_error to_client 404 ("Missing: " ^ leaf)
            | `File ->
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
          )
    ) in

  let () =
    Lwt_unix.(setsockopt server_socket SO_REUSEADDR) true;
    Lwt_unix.(bind server_socket (ADDR_INET (Unix.inet_addr_loopback, 8000)));
    Lwt_unix.listen server_socket 5;
    Zeroinstall.Python.async (fun () ->
      while_lwt true do
        lwt (connection, _client_addr) = Lwt_unix.accept server_socket in
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

        lwt () =
          if Str.string_match re_http_get request 0 then (
            let resource = Str.matched_group 1 request in
            let _host, path = Support.Urlparse.split_path resource in
            let to_client = Lwt_io.of_fd ~mode:Lwt_io.output connection in
            lwt () = handle_request path to_client in
            Lwt_io.flush to_client
          ) else (
            log_warning "Bad HTTP request '%s'" request;
            Lwt.return ();
          ) in

        log_info "Closing connection";

        Lwt_unix.close connection
      done
    )
  in
  object
    method expect requests =
      let to_step = function
        | `File r -> (r, `File) in
      expected := requests |> List.map ( function
        | `File _ as r -> [to_step r]
        | `Parallel rs -> List.map to_step rs
      )
    method terminate =
      log_info "Server shutdown";
      Lwt_unix.(shutdown server_socket SHUTDOWN_ALL)
  end

let with_server fn =
  Fake_system.with_fake_config (fun (config, f) ->
    U.finally_do
      (fun s -> s#terminate)
      (start_server config.Zeroinstall.General.system)
      (fun server -> fn (config, f) server)
  )
