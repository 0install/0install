(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common

module U = Support.Utils
module Q = Support.Qdom
module J = Yojson.Basic

let read_line ch =
  Lwt.catch
    (fun () -> Lwt_io.read_line ch >|= fun line -> Some line)
    (function
      | Lwt_io.Channel_closed _ | End_of_file -> Lwt.return None
      | ex -> Lwt.fail ex
    )

(* Read the next chunk from the channel.
   Returns [None] if the channel was closed. *)
let read_chunk ch : J.json option Lwt.t =
  read_line ch >>= function
  | None -> Lwt.return None
  | Some size ->
      let size = U.safe_int_of_string size in
      let buf = Bytes.create size in
      Lwt_io.read_into_exactly ch buf 0 size >>= fun () ->
      let buf = Bytes.unsafe_to_string buf in
      log_info "Message from peer: %s" buf;
      Lwt.return (Some (J.from_string buf))

let read_xml_chunk ch =
  read_line ch >>= function
  | None -> raise_safe "Got end-of-stream while waiting for XML chunk"
  | Some size ->
      let size = U.safe_int_of_string size in
      let buf = Bytes.create size in
      Lwt_io.read_into_exactly ch buf 0 size >|= fun () ->
      let buf = Bytes.unsafe_to_string buf in
      Q.parse_input None (Xmlm.make_input (`String (0, buf)))

type opt_xml = [J.json | `WithXML of J.json * Q.element ]

type t = {
  from_peer : Lwt_io.input_channel;
  to_peer : Lwt_io.output_channel;
  pending_replies : (string, opt_xml Lwt.u) Hashtbl.t;
  mutable last_ticket : int64;
}

type 'a handler = (string * Yojson.Basic.json list) -> [opt_xml | `Bad_request] Lwt.t

let send_json t ?xml request : unit Lwt.t =
  let data = J.to_string request in
  let xml = xml |> pipe_some (fun xml -> Some (Q.to_utf8 xml)) in
  log_info "Sending to peer: %s%s" data
    (match xml with None -> "" | Some xml -> "\n" ^ xml);
  let xml_buf_len = (match xml with None -> 0 | Some xml -> String.length xml + 12) in
  let buf = Buffer.create (String.length data + 12 + xml_buf_len) in
  Buffer.add_string buf @@ Printf.sprintf "0x%08x\n" (String.length data + 1);
  Buffer.add_string buf data;
  Buffer.add_char buf '\n';
  xml |> if_some (fun xml ->
    Buffer.add_string buf @@ Printf.sprintf "0x%08x\n" (String.length xml + 1);
    Buffer.add_string buf xml;
    Buffer.add_char buf '\n';
  );
  let data = Buffer.contents buf in
  Lwt_io.write t.to_peer data

let take_ticket t =
  t.last_ticket <- Int64.add t.last_ticket 1L;
  Int64.to_string t.last_ticket


let handle_invoke t ~handle_request ticket op args () =
  Lwt.catch
    (fun () ->
      handle_request (op, args) >|= function
      | #J.json as json ->
          ([`String "ok"; json], None)
      | `WithXML (json, attached_xml) ->
          ([`String "ok+xml"; json], Some attached_xml)
      | `Bad_request -> raise_safe "Invalid arguments for '%s': %s" op (J.to_string (`List args))
    )
    (function
      | Safe_exception (msg, _) as ex ->
          log_warning ~ex "Returning error to peer";
          Lwt.return ([`String "fail"; `String msg], None)
      | ex -> Lwt.fail ex
    )
  >>= fun (response, xml) ->
  match ticket with
  | `String _ as ticket -> send_json t ?xml @@ `List (`String "return" :: ticket :: response)
  | `Null -> Lwt.return ()  (* No reply requested *)

let listen t handle_request =
  let rec loop () =
    read_chunk t.from_peer >>= function
    | None -> log_debug "handle_messages: channel closed, so stopping handler"; return `Finished
    | Some (`List [`String "invoke"; (`String _ | `Null as ticket); `String op; `List args]) ->
        U.async @@ handle_invoke t ~handle_request ticket op args; loop ()
    | Some (`List [`String "return"; `String ticket; `String success; result]) ->
        let resolver =
          try Hashtbl.find t.pending_replies ticket
          with Not_found -> raise_safe "Unknown ticket ID: %s" ticket in
        Hashtbl.remove t.pending_replies ticket;
        begin match success with
        | "ok" -> Lwt.wakeup resolver (result :> opt_xml); Lwt.return ()
        | "ok+xml" -> read_xml_chunk t.from_peer >|= fun xml -> Lwt.wakeup resolver (`WithXML (result, xml))
        | "fail" -> Lwt.wakeup_exn resolver (Safe_exception (J.Util.to_string result, ref [])); Lwt.return ()
        | _ -> raise_safe "Invalid success type '%s' from peer:\n" success
        end >>= loop
    | Some json -> raise_safe "Invalid JSON from peer:\n%s" (J.to_string json) in
  loop () >|= fun `Finished -> ()

(** Send a JSON message to the peer and return whatever data it sends back. *)
let invoke t ?xml op args =
  Lwt.catch
    (fun () ->
      let (response, resolver) = Lwt.wait () in
      let ticket = take_ticket t in
      Hashtbl.add t.pending_replies ticket resolver;
      send_json t ?xml (`List [`String "invoke"; `String ticket; `String op; `List args]) >>= fun () ->
      response
    )
    (function
      | Safe_exception _ as ex -> reraise_with_context ex "... invoking %s(%s)" op (J.to_string (`List args))
      | ex -> Lwt.fail ex
    )

(** Send a one-way message (with no ticket). *)
let notify t ?xml op args =
  send_json t ?xml (`List [`String "invoke"; `Null; `String op; `List args])

let create ~from_peer ~to_peer (make_handler:t -> _ handler) =
  let t = {
    from_peer;
    to_peer;
    pending_replies = Hashtbl.create 10;
    last_ticket = 0L;
  } in
  (t, listen t (make_handler t))

let client ~from_peer ~to_peer make_handler =
  read_chunk from_peer >|= function
  | None -> raise_safe "End-of-stream while waiting for set-api-version message"
  | Some (`List [`String "invoke"; `Null; `String "set-api-version"; `List [`String v]]) ->
      let t, thread = create ~from_peer ~to_peer make_handler in
      (t, thread, Version.parse v)
  | Some json ->
      raise_safe "JSON client expected set-api-version message, but got %S" (J.to_string json)

let server ~api_version ~from_peer ~to_peer make_handler =
  let t, thread = create ~from_peer ~to_peer make_handler in
  (t, notify t "set-api-version" [`String (Version.to_string api_version)] >>= fun () -> thread)

let pp_opt_xml f = function
  | `WithXML (json, _) -> Format.fprintf f "%s+XML" (J.to_string json)
  | #J.json as json -> Format.pp_print_string f (J.to_string json)
