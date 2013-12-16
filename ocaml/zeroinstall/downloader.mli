(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Low-level download interface *)

type download_result =
 [ `aborted_by_user
 | `network_failure of string
 | `tmpfile of Support.Common.filepath ]

exception Unmodified

val interceptor :
  (?if_slow:unit Lazy.t ->
   ?size:Int64.t ->
   ?modification_time:float ->
   out_channel ->
   string ->
   [ `network_failure of string | `redirect of string | `success ] Lwt.t)
  option ref

class ['a] downloader : (#Ui.ui_handler as 'a) Lazy.t -> max_downloads_per_site:int ->
  object
    method download : 'a. switch:Lwt_switch.t -> ?modification_time:float -> ?if_slow:(unit Lazy.t) ->
                      ?size:Int64.t -> ?start_offset:Int64.t -> ?hint:([< Feed_url.parsed_feed_url] as 'a) ->
                      string -> download_result Lwt.t

    method ui : 'a
  end
