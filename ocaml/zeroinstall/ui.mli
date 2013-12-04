(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Common types for user interface callbacks *)

type key_vote_type = Good | Bad
type key_vote = (key_vote_type * string)

class type ui_handler =
  object
    (** A new download has been added (may still be queued).
     * @param cancel function to call to cancel the download
     * @param url the URL being downloaded (used in the console display)
     * @param progress a signal of (bytes-so-far, total-expected)
     * @param hint the feed associated with this download
     * @param id a unique ID for this download *)
    method start_monitoring : cancel:(unit -> unit Lwt.t) -> url:string -> progress:(Int64.t * Int64.t option) Lwt_react.S.t ->
                              ?hint:string -> id:string -> unit Lwt.t

    (** A download has finished (successful or not) *)
    method stop_monitoring : string -> unit Lwt.t

    (** Ask the user to confirm they trust at least one of the signatures on this feed.
     * @param key_info a list of fingerprints and their (eventual) votes
     * Return the list of fingerprints the user wants to trust. *)
    method confirm_keys : [`remote_feed of General.feed_url] -> (Support.Gpg.fingerprint * key_vote list Lwt.t) list -> Support.Gpg.fingerprint list Lwt.t

    (** Display a confirmation request *)
    method confirm : string -> [`ok | `cancel] Lwt.t
  end

class console_ui : ui_handler
class batch_ui : ui_handler
