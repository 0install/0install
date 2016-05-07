(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Low-level download interface *)

type download_result =
 [ `Aborted_by_user
 | `Network_failure of string
 | `Tmpfile of Support.Common.filepath ]

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

(* For use by unit-tests *)
val interceptor :
  (?if_slow:unit Lazy.t ->
   ?size:Int64.t ->
   ?modification_time:float ->
   out_channel ->
   string ->
   [ `Network_failure of string | `Redirect of string | `Success | `Aborted_by_user ] Lwt.t)
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

class type download_pool =
  object
    method with_monitor : monitor -> downloader
    method release : unit
  end

val make_pool : max_downloads_per_site:int -> download_pool
