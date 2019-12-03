(* Copyright (C) 2019, Thomas Leonard
   See the README file for details, or visit http://0install.net. *)

(** Generic interface for HTTP libraries (ocurl or ocaml-tls) *)

val escape : string -> string
(** [escape s] %-escapes unsafe characters in [s] so that it can be used in a URL's path component. *)

val variant : string
(** Describes this HTTP-backend. Displayed in the output of "0install --version". *)

module Connection : sig
  type t

  val create : unit -> t

  val release : t -> unit

  val get :
    cancelled:bool ref ->
    ?size:int64 ->
    ?modification_time:float ->
    ?start_offset:int64 ->
    progress:(int64 * int64 option * bool -> unit) ->
    t ->
    out_channel ->
    string ->
    [ `Aborted_by_user
    | `Network_failure of string
    | `Redirect of string
    | `Success
    | `Unmodified ] Lwt.t
  (** @param expected size (if known), including the [start_offset] skipped bytes *)
end

val post :
  data:string ->
  string ->
  (string, (string * string)) result Lwt.t
(** [post ~data url] sends [data] to [url] and returns the body of the response from the server on success.
    On failure, it returns a suitable error message and the body from the server. *)
