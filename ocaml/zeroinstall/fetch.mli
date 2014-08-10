(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

type fetch_feed_response =
  [ `update of (Support.Qdom.element * fetch_feed_response Lwt.t option)  (* Use this version (but a better version may come soon) *)
  | `aborted_by_user        (* Abort silently (no need to notify the user) *)
  | `problem of (string * fetch_feed_response Lwt.t option)    (* Report a problem (but may still succeed later) *)
  | `no_update ]            (* Use the previous version *)

class type fetcher =
  object
    method download_and_import_feed : Feed_url.remote_feed -> fetch_feed_response Lwt.t
    method download_impls : Impl.generic_implementation list -> [ `success | `aborted_by_user ] Lwt.t

    (** [import_feed url xml] checks the signature on [xml] and imports it into the cache if trusted.
     * If not trusted, it confirms with the user first, downloading any missing keys first. *)
    method import_feed : Feed_url.remote_feed -> string -> unit Lwt.t

    (** Download the icon and add it to the disk cache as the icon for the given feed. *)
    method download_icon : Feed_url.non_distro_feed -> string -> unit Lwt.t

    method ui : Progress.watcher
  end

(** Create a fetcher for this platform. *)
val make : General.config -> Trust.trust_db -> Distro.distribution -> Downloader.download_pool -> #Progress.watcher -> fetcher
