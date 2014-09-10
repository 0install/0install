(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Explaining why a solve failed or gave an unexpected answer. *)

(** Why did this solve fail? We take the partial solution from the solver and show,
    for each component we couldn't select, which constraints caused the candidates
    to be rejected. *)
val get_failure_reason : General.config -> Solver.result -> string
