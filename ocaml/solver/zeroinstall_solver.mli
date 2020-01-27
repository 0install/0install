(* Copyright (C) 2020, Thomas Leonard
   See the README file for details, or visit http://0install.net. *)

module S = S

(** Select a compatible set of components to run a program.
    See [Zeroinstall.Solver] for the instantiation of this functor on the
    actual 0install types. *)
module Make(Input : S.SOLVER_INPUT) : sig
  module Output : S.SOLVER_RESULT with module Input = Input

  (** [do_solve model req] finds an implementation matching the given requirements, plus any other implementations needed
      to satisfy its dependencies.
      @param closest_match adds a lowest-ranked (but valid) implementation ([Input.dummy_impl]) to
        every interface, so we can always select something. Useful for diagnostics.
        You should ensure that [Input.get_command] always returns a dummy command for dummy_impl too.
        Note: always try without [closest_match] first, or it may miss a valid solution.
      @return None if the solve fails (only happens if [closest_match] is false). *)
  val do_solve : closest_match:bool -> Input.requirements -> Output.t option
end

(** Explaining why a solve failed or gave an unexpected answer. *)
module Diagnostics(Model : S.SOLVER_RESULT) : sig
  (** Why did this solve fail? We take the partial solution from the solver and show,
      for each component we couldn't select, which constraints caused the candidates
      to be rejected.
      @param verbose List all rejected candidates, not just the first few. *)
  val get_failure_reason : ?verbose:bool -> Model.t -> string
end

(** The low-level SAT solver. *)
module Sat = Sat
