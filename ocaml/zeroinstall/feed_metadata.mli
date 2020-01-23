(* Copyright (C) 2020, Thomas Leonard
   See the README file for details, or visit http://0install.net. *)

(** Mutable state associated with feeds. *)

open Support

type t = {
  last_checked : float option;
  user_stability : Stability.t XString.Map.t;
}

val load : General.config -> [< Feed_url.parsed_feed_url] -> t
(** Load per-feed extra data (last-checked time and preferred stability). *)

val save : General.config -> [< Feed_url.parsed_feed_url] -> t -> unit

val update : General.config -> [< Feed_url.parsed_feed_url] -> (t -> t) -> unit
(** [update config url f] loads the metadata for [url], transforms it with [f], and then saves it back. *)

val update_last_checked_time : General.config -> [< Feed_url.remote_feed] -> unit

val stability : string -> t -> Stability.t option 
(** [stability id t] is the user's rating of [id], if any. *)

val with_stability : string -> Stability.t option -> t -> t
(** [with_stability id rating t] is [t] with [id]'s user stability set to [rating]. *)
