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
      let buf = String.create size in
      lwt () = Lwt_io.read_into_exactly ch buf 0 size in
      log_info "Message from peer: %s" buf;
      Lwt.return (Some (J.from_string buf))

class json_connection ~from_peer ~to_peer =
  let handlers = ref StringMap.empty in
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
    lwt response =
      try_lwt
        lwt return_value =
          let cb = StringMap.find op !handlers |? lazy (raise_safe "No handler for JSON op '%s' (received from peer)" op) in
          try_lwt cb args
          with Bad_request -> raise_safe "Invalid arguments for '%s': %s" op (J.to_string (`List args)) in
        Lwt.return [`String "ok"; return_value]
      with Safe_exception (msg, _) as ex ->
        log_warning ~ex "Returning error to peer";
        Lwt.return [`String "fail"; `String msg] in
      send_json @@ `List (`String "return" :: `String ticket :: response) in

  (* Read and process messages from stream until it is closed. *)
  let () =
    async (fun () ->
      try_lwt
        let finished = ref false in
        while_lwt not !finished do
          lwt request = read_chunk from_peer in
          begin match request with
          | None -> log_debug "handle_messages: channel closed, so stopping handler"; finished := true
          | Some (`List [`String "invoke"; `String ticket; `String op; `List args]) ->
              async @@ handle_invoke ticket op args;
          | Some (`List [`String "return"; `String ticket; `String success; result]) ->
              let resolver =
                try Hashtbl.find pending_replies ticket
                with Not_found -> raise_safe "Unknown ticket ID: %s" ticket in
              Hashtbl.remove pending_replies ticket;
              begin match success with
              | "ok" -> Lwt.wakeup resolver result;
              | "fail" -> Lwt.wakeup_exn resolver (Safe_exception (J.Util.to_string result, ref []))
              | _ -> raise_safe "Invalid success type '%s' from peer:\n" success end;
          | Some json -> raise_safe "Invalid JSON from peer:\n%s" (J.to_string json) end;
          Lwt.return ()
        done
      finally
        Lwt.wakeup finish ();
        Lwt.return ()
    ) in

  object
    (** Send a JSON message to the peer and return whatever data it sends back. *)
    method invoke ?xml op args =
      try_lwt
        let (response, resolver) = Lwt.wait () in
        let ticket = take_ticket () in

        Hashtbl.add pending_replies ticket resolver;
        lwt () = send_json ?xml (`List [`String "invoke"; `String ticket; `String op; `List args]) in
        response
      with Safe_exception _ as ex -> reraise_with_context ex "... invoking %s(%s)" op (J.to_string (`List args))

    method register_handler op handler =
      handlers := StringMap.add op handler !handlers

    method run = finished
  end
