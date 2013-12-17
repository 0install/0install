(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Low-level download interface *)

type download_result =
 [ `aborted_by_user
 | `network_failure of string
 | `tmpfile of Support.Common.filepath ]

exception Unmodified

(* (bytes so far, total expected, finished) *)
type progress = (Int64.t * Int64.t option * bool) Lwt_react.signal

type download = {
  cancel : unit -> unit Lwt.t;
  url : string;
  progress : progress;    (* Must keep a reference to this; if it gets GC'd then updates stop. *)
  hint : string option;
}

val is_in_progress : download -> bool

val interceptor :
  (?if_slow:unit Lazy.t ->
   ?size:Int64.t ->
   ?modification_time:float ->
   out_channel ->
   string ->
   [ `network_failure of string | `redirect of string | `success ] Lwt.t)
  option ref

type monitor = download -> unit

type downloader =
  < download : 'b.
      switch:Lwt_switch.t ->
      ?modification_time:float ->
      ?if_slow:(unit Lazy.t) ->
      ?size:Int64.t ->
      ?start_offset:Int64.t ->
      ?hint:([< Feed_url.parsed_feed_url] as 'b) ->
      string -> download_result Lwt.t >

type download_pool = monitor -> downloader

val make_pool : max_downloads_per_site:int -> download_pool
