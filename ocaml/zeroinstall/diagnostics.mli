(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Explaining why a solve failed or gave an unexpected answer. *)

(** Why did this solve fail? We take the partial solution from the solver and show,
    for each component we couldn't select, which constraints caused the candidates
    to be rejected. *)
val get_failure_reason : General.config -> Solver.result -> string

(** Run a solve with a single implementation as the only choice for an interface.
    If no solution is possible, explain why not.
    If a solution is possible, explain why it isn't the preferred solution. *)
val justify_decision : General.config -> Feed_cache.feed_provider -> Requirements.requirements -> General.iface_uri -> Feed.global_id -> string
