(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Queries the configured key info server for advice about GPG keys. *)

type t

val make : General.config -> t

(** [get provider downloader fingerprint] requests information about the given GPG key.
 * If the info is in the cache, returns it immediately.
 * If we are already fetching this information, returns the existing task.
 * If the previous fetch failed, tries again.
 * On error, returns a [Bad] response rather than raising an exception. *)
val get :
  t ->
  download:(switch:Lwt_switch.t -> string -> Downloader.download_result Lwt.t) ->
  Support.Gpg.fingerprint ->
  Progress.key_vote list Lwt.t
