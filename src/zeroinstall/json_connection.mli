(* Copyright (C) 2016, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Communicating over a JSON link.
 *
 * Each message is a length line "0xHHHHHHHH\n" followed by that many bytes of JSON.
 * Each JSON message is one of:
 * - [["invoke", ticket, op, args]]
 * - [["return", ticket, "ok", result]]
 * - [["return", ticket, "ok+xml", result]] followed by another length and an XML document
 * - [["return", ticket, "fail", msg]]
 *
 * The ticket is a unique ID chosen by the sender of the "invoke" message. The same ticket is quoted back
 * in the corresponding "return" or "fail" response.
 *)

open Support

type t

type opt_xml = [Yojson.Basic.t | `WithXML of Yojson.Basic.t * Qdom.element ]
type 'a handler = (string * Yojson.Basic.t list) -> [opt_xml | `Bad_request] Lwt.t

val client :
  from_peer:Lwt_io.input_channel ->
  to_peer:Lwt_io.output_channel ->
  (t -> 'a handler) ->
  (t * unit Lwt.t * Version.t) Lwt.t
(** [client ~from_peer ~to_peer make_handler] is a new connection,
    a thread handling incoming messages, and the protocol version.
    It evaluates [make_handler t] once to get a handler function, which it uses to process
    each message until the stream is closed. Replies are sent back to the peer. *)

val server :
  api_version:Version.t ->
  from_peer:Lwt_io.input_channel ->
  to_peer:Lwt_io.output_channel ->
  (t -> 'a handler) ->
  t * unit Lwt.t
(** Like [client], except that the server starts by sending the version number rather than reading it. *)

val invoke : t -> ?xml:Qdom.element -> string -> Yojson.Basic.t list -> opt_xml Lwt.t
val notify : t -> ?xml:Qdom.element -> string -> Yojson.Basic.t list -> unit Lwt.t

val pp_opt_xml : Format.formatter -> opt_xml -> unit
