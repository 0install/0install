(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Communicating over a JSON link.
 *
 * Each message is a length line "0xHHHHHHHH\n" followed by that many bytes of JSON.
 * Each JSON message is one of:
 * - [["invoke", ticket, op, args]]
 * - [["return", ticket, "ok", result]]
 * - [["return", ticket, "fail", msg]]
 *
 * The ticket is a unique ID chosen by the sender of the "invoke" message. The same ticket is quoted back
 * in the corresponding "return" or "fail" response.
 *)

open Support.Common

module U = Support.Utils
module Q = Support.Qdom
module J = Yojson.Basic

exception Bad_request    (* Throw this from a handler to report a bad request message to the peer. *)

let async fn =
  Lwt.ignore_result (
    try_lwt fn ()
    with ex -> log_warning ~ex "Unhandled error from Lwt thread"; Lwt.fail ex
  )

(* Read the next chunk from the channel.
   Returns [None] if the channel was closed. *)
let read_chunk ch : J.json option Lwt.t =
  lwt size =
    try_lwt
      lwt line = Lwt_io.read_line ch in
      Lwt.return (Some line)
    with Lwt_io.Channel_closed _ | End_of_file -> Lwt.return None in
  match size with
  | None -> Lwt.return None
  | Some size ->
      let size = U.safe_int_of_string size in
      let buf = Bytes.create size in
      let buf = Bytes.unsafe_to_string buf in   (* Needed for old Lwt API *)
      lwt () = Lwt_io.read_into_exactly ch buf 0 size in
      log_info "Message from peer: %s" buf;
      Lwt.return (Some (J.from_string buf))

type json_with_xml =
  [ J.json
  | `WithXML of (J.json * Support.Qdom.element) ]

class json_connection ~from_peer ~to_peer handle_request =
  let finished, finish = Lwt.wait () in

  let send_json ?xml request : unit Lwt.t =
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
    Lwt_io.write to_peer data in

  let pending_replies = Hashtbl.create 10 in
  let take_ticket =
    let last_ticket = ref (Int64.zero) in
    fun () -> (last_ticket := Int64.add !last_ticket Int64.one; Int64.to_string !last_ticket) in

  let handle_invoke ticket op args () =
    let xml = ref None in
    lwt handle_request = handle_request in
    lwt response =
      try_lwt
        lwt return_value =
          try_lwt
            handle_request (op, args) >>= function
            | `WithXML (json, attached_xml) ->
                xml := Some attached_xml;
                Lwt.return json
            | #J.json as json -> Lwt.return json
          with Bad_request -> raise_safe "Invalid arguments for '%s': %s" op (J.to_string (`List args)) in
        Lwt.return [`String (if !xml = None then "ok" else "ok+xml"); return_value]
      with Safe_exception (msg, _) as ex ->
        log_warning ~ex "Returning error to peer";
        Lwt.return [`String "fail"; `String msg] in
    send_json ?xml:!xml @@ `List (`String "return" :: `String ticket :: response) in

  let rec loop () =
    read_chunk from_peer >>= function
    | None -> log_debug "handle_messages: channel closed, so stopping handler"; return `Finished
    | Some (`List [`String "invoke"; `String ticket; `String op; `List args]) ->
        async @@ handle_invoke ticket op args; loop ()
    | Some (`List [`String "return"; `String ticket; `String success; result]) ->
        let resolver =
          try Hashtbl.find pending_replies ticket
          with Not_found -> raise_safe "Unknown ticket ID: %s" ticket in
        Hashtbl.remove pending_replies ticket;
        begin match success with
        | "ok" -> Lwt.wakeup resolver result;
        | "fail" -> Lwt.wakeup_exn resolver (Safe_exception (J.Util.to_string result, ref []))
        | _ -> raise_safe "Invalid success type '%s' from peer:\n" success end;
        loop ()
    | Some json -> raise_safe "Invalid JSON from peer:\n%s" (J.to_string json) in

  (* Read and process messages from stream until it is closed. *)
  let () =
    async (fun () ->
      Lwt.catch (fun () ->
        loop () >|= fun `Finished ->
        Lwt.wakeup finish ();
      ) (fun ex ->
        Lwt.wakeup_exn finish ex;
        Lwt.return ()
      )
    ) in

  object
    (** Send a JSON message to the peer and return whatever data it sends back. *)
    method invoke ?xml op args =
      try_lwt
        let (response, resolver) = Lwt.wait () in
        let ticket = take_ticket () in

        Hashtbl.add pending_replies ticket resolver;
        send_json ?xml (`List [`String "invoke"; `String ticket; `String op; `List args]) >>= fun () ->
        response
      with Safe_exception _ as ex -> reraise_with_context ex "... invoking %s(%s)" op (J.to_string (`List args))

    (** Send a one-way message (with no ticket). *)
    method notify ?xml op args =
      send_json ?xml (`List [`String "invoke"; `Null; `String op; `List args])

    method run = finished
  end
