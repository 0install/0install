(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Common types for user interface callbacks *)

open Support.Common

type progress_reporter = <
  (* A new download has been added (may still be queued) *)
  start_monitoring : cancel:(unit -> unit) -> url:string -> hint:string -> size:(Int64.t option) -> tmpfile:filepath -> unit Lwt.t;

  (* A download has finished (successful or not) *)
  stop_monitoring : filepath -> unit Lwt.t;
>
