open Support
open Support.Common

module Certificates = struct
  (* Possible certificate files; stop after finding one.
     Based on https://golang.org/src/crypto/x509 *)
  let cert_files = [
    "/etc/ssl/certs/ca-certificates.crt";                (* Debian/Ubuntu/Gentoo etc. *)
    "/etc/pki/tls/certs/ca-bundle.crt";                  (* Fedora/RHEL 6 *)
    "/etc/ssl/ca-bundle.pem";                            (* OpenSUSE *)
    "/etc/pki/tls/cacert.pem";                           (* OpenELEC *)
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"; (* CentOS/RHEL 7 *)
    "/etc/ssl/cert.pem";                                 (* Alpine Linux / OpenBSD *)
  
    "/var/ssl/certs/ca-bundle.crt";           (* AIX *)
  
    "/usr/local/etc/ssl/cert.pem";            (* FreeBSD *)
    "/usr/local/share/certs/ca-root-nss.crt"; (* DragonFly *)
    "/etc/openssl/certs/ca-certificates.crt"; (* NetBSD *)
  
    "/sys/lib/tls/ca.pem";                (* Plan9 *)
  
    "/etc/certs/ca-certificates.crt";     (* Solaris 11.2+ *)
    "/etc/ssl/cacert.pem";                (* OmniOS *)
  ]
  
  (* Possible directories with certificate files; stop after successfully
     reading at least one file from a directory.
     Based on https://golang.org/src/crypto/x509/root_unix.go *)
  let cert_directories = [
    "/etc/ssl/certs";               (* Debian, SLES10/SLES11, https://golang.org/issue/12139 *)
    "/system/etc/security/cacerts"; (* Android *)
    "/usr/local/share/certs";       (* FreeBSD *)
    "/etc/pki/tls/certs";           (* Fedora/RHEL *)
    "/etc/openssl/certs";           (* NetBSD *)
    "/var/ssl/certs";               (* AIX *)
  ]
  
  let is_file path =
    log_debug "Checking for certificate file %S" path;
    match Unix.stat path with
    | x -> x.Unix.st_kind = Unix.S_REG;
    | exception _ -> false
  
  let is_dir path =
    log_debug "Checking for certificate directory %S" path;
    match Unix.stat path with
    | x -> x.Unix.st_kind = Unix.S_DIR;
    | exception _ -> false
  
  let ctx = lazy (
    let ctx = Conduit_lwt_unix_ssl.Client.create_ctx () in
    begin
      match List.find_opt is_file cert_files with
      | Some cert_file -> Ssl.load_verify_locations ctx cert_file ""
      | None ->
        match List.find_opt is_dir cert_directories with
        | Some dir -> Ssl.load_verify_locations ctx "" dir
        | None ->
          log_warning "@[<v2>No certificates found! I tried these files:@,%a@]@.@[<v2>and these directories:@,%a@]@.Hint: try installing 'ca-certificates'@."
            Format.(pp_print_list ~pp_sep:pp_print_cut pp_print_string) cert_directories
            Format.(pp_print_list ~pp_sep:pp_print_cut pp_print_string) cert_files;
    end;
    ctx
  )
end

module Net = struct
  module IO = struct
    (* [Cohttp_lwt_unix.IO] requires us to provide a [Conduit_lwt_unix.flow], but that type is private.
       It can only be created by [Conduit_lwt_unix], which doesn't let us specify the CA certificates.
       Luckily, cohttp doesn't need it for anything, so just use unit here instead. *)
    include (Cohttp_lwt_unix.IO : Cohttp_lwt.S.IO
             with type ic = Lwt_io.input_channel
              and type oc = Lwt_io.output_channel
              and type conn := Conduit_lwt_unix.flow
              and type error = exn)
    type conn = unit
  end

  include (Cohttp_lwt_unix.Net : module type of Cohttp_lwt_unix.Net with module IO := Cohttp_lwt_unix.IO)

  (* Look up the IP address of host. Return an IPv4 address if available, or an IPv6 one if not. *)
  let ip_of_host host =
    Lwt_unix.getaddrinfo host "" [Lwt_unix.AI_SOCKTYPE SOCK_STREAM] >|= fun addrs ->
    match List.find_opt (fun i -> i.Unix.ai_family = Unix.PF_INET) addrs with
    | Some { Unix.ai_addr = Unix.ADDR_INET (ipv4_addr, _port); _ } -> Ipaddr_unix.of_inet_addr ipv4_addr
    | _ ->
      match List.find_opt (fun i -> i.Unix.ai_family = Unix.PF_INET6) addrs with
      | Some { Unix.ai_addr = Unix.ADDR_INET (addr, _port); _ } -> Ipaddr_unix.of_inet_addr addr
      | _ -> Safe_exn.failf "No IP address found for hostname %S" host

  let connect_uri ~ctx uri =
    match Uri.host uri with
    | None -> Safe_exn.failf "Missing host in URI %a" Uri.pp uri
    | Some host ->
      ip_of_host host >>= fun ip ->
      match Uri.scheme uri with
      | Some "http" ->
        let port = Uri.port uri |> default 80 in
        Conduit_lwt_unix.connect ~ctx:ctx.Cohttp_lwt_unix.Net.ctx (`TCP (`IP ip, `Port port)) >|= fun (_flow, ic, oc) ->
        ((), ic, oc)
      | Some "https" ->
        let port = Uri.port uri |> default 443 in
        (* Force use of OpenSSL because conduit's ocaml-tls support disables certificate validation. *)
        let sa = Unix.ADDR_INET (Ipaddr_unix.to_inet_addr ip ,port) in
        Conduit_lwt_unix_ssl.Client.connect ~ctx:(Lazy.force Certificates.ctx) ~hostname:host sa >|= fun (_fd, ic, oc) ->
        ((), ic, oc)
      | Some s -> Safe_exn.failf "Unsupported scheme %S in %a" s Uri.pp uri
      | None -> Safe_exn.failf "Missing URI scheme in %a" Uri.pp uri
end

module Client = Cohttp_lwt.Make_client(Net.IO)(Net)

let next s =
  Lwt.catch
    (fun () -> Lwt_stream.next s >|= fun x -> Ok x)
    (function
      | Lwt_stream.Empty -> Lwt.return (Error `End_of_stream)
      | ex -> Lwt.fail ex
    )

(* Drop (up to) the first [n] bytes from [str], updating [n] in the process. *)
let drop n str =
  if !n = 0L then str
  else (
    let len = Int64.of_int (String.length str) in
    if len <= !n then (
      n := Int64.sub !n len;
      ""
    ) else (
      let str = XString.tail str (Int64.to_int !n) in
      n := 0L;
      str
    )
  )

let day_name tm =
  match tm.Unix.tm_wday with
  | 0 -> "Sun"
  | 1 -> "Mon"
  | 2 -> "Tue"
  | 3 -> "Wed"
  | 4 -> "Thu"
  | 5 -> "Fri"
  | 6 -> "Sat"
  | x -> failwith (Printf.sprintf "Invalid day number %d!" x)

let month_name tm =
  match tm.Unix.tm_mon with
  | 0 -> "Jan"
  | 1 -> "Feb"
  | 2 -> "Mar"
  | 3 -> "Apr"
  | 4 -> "May"
  | 5 -> "Jun"
  | 6 -> "Jul"
  | 7 -> "Aug"
  | 8 -> "Sep"
  | 9 -> "Oct"
  | 10 -> "Nov"
  | 11 -> "Dec"
  | x -> failwith (Printf.sprintf "Invalid month number %d!" x)

let if_modified_since time headers =
  match time with
  | None -> headers
  | Some time ->
    let tm = Unix.gmtime time in
    let date = Printf.sprintf "%s, %02d %s %d %2d:%2d:%2d GMT"
        (day_name tm) (tm.Unix.tm_mday) (month_name tm) (tm.Unix.tm_year + 1900)
        tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
    in
    Cohttp.Header.add headers "If-Modified-Since" date

let user_agent = Printf.sprintf "0install/%s (cohttp)" About.version

let set_user_agent headers =
  Cohttp.Header.prepend_user_agent headers user_agent

module Proxy : sig
  type t

  val create : unit -> t
  (** Read proxy settings from environment. *)

  val get : t -> Uri.t -> Uri.t option
  (** [get t uri] returns the proxy to use to access [uri]. *)
end = struct
  (* http_proxy's format doesn't seem to be specified anywhere. Try to do what libcurl does. *)

  type t = {
    http : Uri.t option Lazy.t;
    https : Uri.t option Lazy.t;
  }

  (* We don't know whether the value has a scheme or not. [Uri.of_string] will interpret e.g. "foo:bar"
     as having scheme "foo", which isn't what we want. *)
  let re_scheme = Str.regexp {|^[A-Za-z][-A-Za-z0-9+.]\+://|}

  let try_var var =
    match Unix.getenv var with
    | exception Not_found -> None
    | "" -> None
    | proxy ->
      log_debug "Found %s=%S" var proxy;
      try
        if Str.string_match re_scheme proxy 0 then Some (Uri.of_string proxy)
        else Some (Uri.of_string ("http://" ^ proxy))
      with ex ->
        log_warning ~ex "Failed to parse $%s value %S (should be e.g. 'http://host:port')" var proxy;
        None

  let get scheme =
    match try_var (scheme ^ "_proxy") with
    | Some _ as proxy -> proxy
    | None -> try_var "all_proxy"

  let create () =
    {
      http = lazy (get "http");
      https = lazy (get "https");
    }

  let get t uri =
    match Uri.scheme uri with
    | Some "http" -> Lazy.force t.http
    | Some "https" -> Lazy.force t.https
    | _ -> None
end

(* We take a [fn] to process the result rather than returning the result directly
   because we have to use [callv], which drains the body as soon as you ask for
   the next response. *)
let http ?(body=Cohttp_lwt.Body.empty) ~proxy ~headers meth url fn =
  let req = Cohttp.Request.make_for_client ~headers ~chunked:false meth url in
  let req, proxy =
    match Proxy.get proxy url with
    | None -> req, url
    | Some proxy -> {req with Cohttp.Request.resource = Uri.to_string url}, proxy
  in
  Lwt.catch
    (fun () ->
       (* We only want to make one call, but only [callv] lets us pass in a
          Request, which we need to do in order to support proxies. *)
       Client.callv proxy (Lwt_stream.of_list [req, body]) >>= fun resps ->
       Lwt_stream.map_s fn resps |> Lwt_stream.to_list >|= function
       | [] -> failwith "callv didn't return any responses!"
       | [x] -> x
       | _ -> failwith "callv returned multiple responses!"
    )
    (fun ex ->
       let m = Cohttp.Code.string_of_method meth in
       log_warning ~ex "HTTP %s of %a failed" m Uri.pp url;
       Lwt.return (`Network_failure (Format.asprintf "@[<h>HTTP %s of %a failed: %s@]" m Uri.pp url (Printexc.to_string ex)))
    )

let check_size ~url ~actual_size = function
  | Some expected when expected <> actual_size ->
    `Network_failure (Format.asprintf
                        "@[<v>Downloaded archive has incorrect size.@,\
                         URL: %a@,\
                         Expected: %Ld bytes@,\
                         Received: %Ld bytes@]" Uri.pp url expected actual_size)
  | _ ->
    log_info "Download '%a' completed successfully (%Ld bytes)" Uri.pp url actual_size;
    `Success

(* Download the contents of [url] into [ch]. *)
let download_no_follow ~proxy ~cancelled ?size ?modification_time ~start_offset ~progress ch url =
  let skip_bytes = ref start_offset in
  let headers = Cohttp.Header.init ()
                |> if_modified_since modification_time
                |> set_user_agent
  in
  log_info "HTTP GET %S" url;
  let url = Uri.of_string url in
  http `GET ~proxy ~headers url @@ fun (resp, body) ->
    let body = Cohttp_lwt.Body.to_stream body in
    let headers = Cohttp.Response.headers resp in
    match Cohttp.Response.status resp, Cohttp.Header.get headers "location" with
    | #Cohttp.Code.redirection_status, Some target ->
      let rel_target = Uri.of_string target in
      let target = Uri.resolve "http" url rel_target in
      log_info "Redirect from '%a' to '%a' (%a)" Uri.pp url Uri.pp rel_target Uri.pp target;
      Lwt.return (`Redirect (Uri.to_string target))
    | `Not_modified, _ ->
      Lwt.return `Unmodified
    | `OK, _ ->
      begin
        let progress_total_size =
          match size with
          | Some _ -> size
          | None -> (* We don't know the expected length, but maybe the server told us in the headers: *)
            match Cohttp.Header.get headers "content-length" with
            | None -> None
            | Some len -> Int64.of_string_opt len
        in
        let rec copy total =
          if !cancelled then Lwt.return `Aborted_by_user
          else (
            next body >>= function
            | Error `End_of_stream -> Lwt.return (`Success total)
            | Ok data ->
              let total = Int64.add total (Int64.of_int (String.length data)) in
              match size with
              | Some limit when total > limit ->
                Lwt.return (`Network_failure "Download exceeded expected size!")
              | _ ->
                progress (total, progress_total_size, false);
                let data = drop skip_bytes data in
                begin
                  try
                    output_string ch data;
                  with ex ->
                    log_warning ~ex "Failed to write download data to temporary file";
                    Safe_exn.failf "Failed to write download data to temporary file: %s" (Printexc.to_string ex);
                end;
                copy total
          )
        in
        copy 0L >|= function
        | `Network_failure _ | `Aborted_by_user as e -> e
        | `Success actual_size -> check_size ~url ~actual_size size
      end
    | status, _ ->
      let msg = Format.asprintf "@[<h>Error downloading '%a': The requested URL returned error: %d@]"
          Uri.pp url
          (Cohttp.Code.code_of_status status)
      in
      Lwt.return (`Network_failure msg)

module Ftp = struct
  let read_reply from_server =
    Lwt_io.read_line from_server >>= fun line ->
    log_info "FTP: <<< %S" line;
    match line.[3] with
    | ' ' -> Lwt.return line
    | '-' ->
      let end_pattern = String.sub line 0 3 ^ " " in
      let rec aux () =
        Lwt_io.read_line from_server >>= fun extra ->
        log_info "FTP: <<< %S" extra;
        if XString.starts_with extra end_pattern then Lwt.return line
        else aux ()
      in
      aux ()
    | _ -> Safe_exn.failf "Invalid FTP response %S" line

  let read_complete_reply from_server =
    read_reply from_server >|= fun line ->
    if line.[0] <> '2' then Safe_exn.failf "Error from FTP server: %S" line

  let await_completion from_server =
    read_reply from_server >>= fun line ->
    match line.[0] with
    | '1' -> read_complete_reply from_server
    | _ -> Safe_exn.failf "Invalid FTP response %S (expected '1xx' code) " line

  let send sock cmd =
    log_info "FTP: >>> %S" cmd;
    if String.contains cmd '\n' || String.contains cmd '\r' then
      Safe_exn.failf "Newline in FTP command %S!" cmd;
    let cmd = cmd ^ "\r\n" in
    let rec aux start =
      let len = String.length cmd - start in
      if len = 0 then Lwt.return ()
      else  (
        Lwt_unix.write_string sock cmd start len >>= fun sent ->
        assert (sent > 0);
        aux (start + sent)
      )
    in
    aux 0

  (* https://tools.ietf.org/html/rfc1123#page-31 says:
     "The format of the 227 reply to a PASV command is not well standardized." *)
  let re_passive_response = Str.regexp {|.*[0-9]+,[0-9]+,[0-9]+,[0-9]+,\([0-9]+\),\([0-9]+\)|}

  (* Request a passive-mode transmission, and return the new port number. *)
  let initiate_passive sock from_server =
      send sock "PASV" >>= fun () ->
      read_reply from_server >|= fun data_addr ->
      if not (XString.starts_with data_addr "227 ") then
        Safe_exn.failf "Expected 227 reply to PASV, but got %S" data_addr;
      if Str.string_match re_passive_response data_addr 0 then (
        let port_high = Str.matched_group 1 data_addr |> int_of_string in
        let port_low = Str.matched_group 2 data_addr |> int_of_string in
        (port_high lsl 8) + port_low
      ) else (
        Safe_exn.failf "Failed to parse %S as a passive address" data_addr
      )

  (* Connect to the passive endpoint [host, port] and then start a background
     thread to download the data from it. *)
  let download_data ?size ~start_offset ~progress ~cancelled ~host ~port ch =
    let skip_bytes = ref start_offset in
    let connected, set_connected = Lwt.wait () in
    let sock = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
    let thread =
      Lwt.finalize
        (fun () ->
           Lwt.catch
             (fun () ->
                Lwt_unix.connect sock (Unix.ADDR_INET (host, port)) >>= fun () ->
                Lwt.wakeup set_connected ();
                let buf = Bytes.create 4096 in
                let rec aux so_far =
                  progress (so_far, size, false);
                  Lwt_unix.recv sock buf 0 (Bytes.length buf) [] >>= fun got ->
                  if got = 0 then Lwt.return so_far
                  else if !cancelled then Lwt.(fail Canceled)
                  else (
                    let got64 = Int64.of_int got in
                    if !skip_bytes >= got64 then (
                      skip_bytes := Int64.sub !skip_bytes got64;
                    ) else (
                      output ch buf (Int64.to_int !skip_bytes) got;
                      skip_bytes := 0L;
                    );
                    aux (Int64.add so_far (Int64.of_int got))
                  )
                in
                aux 0L
             )
             (fun ex ->
                log_warning ~ex "FTP download failed";
                Lwt.fail ex
             )
        )
        (fun () -> Lwt_unix.close sock)
    in
    connected >|= fun () -> `Ready thread

  let get ~cancelled ?size ?modification_time ~start_offset ~progress ch url =
    ignore modification_time;
    match Uri.host url with
    | None -> Safe_exn.failf "Missing host in URL %a" Uri.pp url
    | Some host ->
      let path = Uri.path url in
      Net.ip_of_host host >>= fun ip ->
      let addr = Ipaddr_unix.to_inet_addr ip in
      log_info "FTP: resolved host %S to address %s" host (Unix.string_of_inet_addr addr);
      let port = Uri.port url |> default 21 in
      let sock = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
      Lwt.finalize
        (fun () ->
           Lwt_unix.connect sock (Unix.ADDR_INET (addr, port)) >>= fun () ->
           let from_server = Lwt_io.(of_fd ~mode:input) sock in
           read_complete_reply from_server >>= fun () ->
           send sock "USER anonymous" >>= fun () ->
           read_reply from_server >>= fun line ->
           begin match line.[0] with
             | '2' -> Lwt.return ()
             | '3' ->
               send sock "PASS anonymous@" >>= fun () ->
               read_complete_reply from_server
             | _ -> Safe_exn.failf "Anonymous FTP login failed: %S" line
           end >>= fun () ->
           send sock "TYPE I" >>= fun () ->
           read_complete_reply from_server >>= fun () ->
           initiate_passive sock from_server >>= fun pasv_port ->
           download_data ?size ~start_offset ~progress ~cancelled ~host:addr ~port:pasv_port ch >>= fun (`Ready thread) ->
           let dir = Filename.dirname path in
           send sock ("CWD " ^ dir) >>= fun () ->
           read_complete_reply from_server >>= fun () ->
           send sock ("RETR " ^ Filename.basename path) >>= fun () ->
           await_completion from_server >>= fun () ->
           thread >|= fun actual_size ->
           check_size size ~url ~actual_size
        )
        (fun () -> Lwt_unix.close sock)
end

let post ~data url =
  let url = Uri.of_string url in
  let body = Cohttp_lwt.Body.of_string data in
  let headers = Cohttp.Header.init ()
                |> set_user_agent in
  let proxy = Proxy.create () in
  http `POST ~proxy ~body ~headers url (fun (resp, body) ->
      Cohttp_lwt.Body.to_string body >|= fun body ->
      match Cohttp.Response.status resp with
      | `OK -> `Success body
      | status ->
        let msg = Format.asprintf "@[<h>Error posting to '%a': The requested URL returned error: %d@]"
            Uri.pp url
            (Cohttp.Code.code_of_status status) in
        `Failed (msg, body)
    ) >|= function
  | `Success body -> Ok body
  | `Failed e -> Error e
  | `Network_failure e -> Error (e, "")

module Connection = struct
  (* Note: it would probably be better to store the proxy configuration on the
     pool rather than on each connection. *)
  type t = Proxy.t

  let create = Proxy.create

  let release _ = ()

  let get ~cancelled ?size ?modification_time ?(start_offset=Int64.zero) ~progress proxy ch url =
    let parsed = Uri.of_string url in
    match Uri.scheme parsed with
    | Some "http" | Some "https" -> download_no_follow ~proxy ~cancelled ?size ?modification_time ~start_offset ~progress ch url
    | Some "ftp" -> Ftp.get ~cancelled ?size ~start_offset ~progress ch parsed
    | Some x -> Safe_exn.failf "Unsupported URI scheme %S in %S" x url
    | None -> Safe_exn.failf "Missing URI scheme in %S" url
end

let escape x = Uri.pct_encode ~component:`Path x

let variant = "cohttp (OCaml)"
