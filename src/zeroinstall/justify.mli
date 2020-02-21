(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Explaining why a particular implementation was or was not chosen. *)

(** Run a solve with a single implementation as the only choice for an interface.
    If no solution is possible, explain why not.
    If a solution is possible, explain why it isn't the preferred solution. *)
val justify_decision : General.config -> Feed_provider.feed_provider -> Requirements.t -> Sigs.iface_uri -> source:bool -> Feed_url.global_id -> string
