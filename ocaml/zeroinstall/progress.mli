(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Used to report progress during a solve *)

type key_vote_type = Good | Bad
type key_vote = (key_vote_type * string)

class type watcher =
  object
    (* An error ocurred (probably a failure to download something). *)
    method report : 'a. ([<Feed_url.parsed_feed_url] as 'a) -> string -> unit

    (* Updates the latest solution. If the first argument is [true] then the solve is
     * usable (although it may improve if you wait). *)
    method update : (bool * Solver.Output.t) * Feed_provider.feed_provider -> unit

    (** A new download has been added (may still be queued). *)
    method monitor : Downloader.download -> unit

    (** Ask the user to confirm they trust at least one of the signatures on this feed.
     * @param key_info a list of fingerprints and their (eventual) votes
     * Return the list of fingerprints the user wants to trust. *)
    method confirm_keys : Feed_url.remote_feed -> (Support.Gpg.fingerprint * key_vote list Lwt.t) list -> Support.Gpg.fingerprint list Lwt.t

    (** Display a confirmation request *)
    method confirm : string -> [`Ok | `Cancel] Lwt.t

    (** Called each time a new implementation is added to the cache.
     * This is used by the GUI to refresh its display. *)
    method impl_added_to_store : unit
  end
