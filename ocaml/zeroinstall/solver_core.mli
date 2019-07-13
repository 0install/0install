(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Select a compatible set of components to run a program.
 * See [Solver] for the instantiation of this functor on the
 * actual 0install types. *)

module Make : functor (Model : Sigs.SOLVER_INPUT) -> sig
  type diagnostics

  type selection = {
    impl : Model.impl;                  (** The implementation chosen to fill the role *)
    commands : Model.command_name list; (** The commands required *)
    diagnostics : diagnostics;          (** Extra information useful for diagnostics *)
  }

  module RoleMap : Map.S with type key = Model.Role.t

  (** [do_solve model req] finds an implementation matching the given requirements, plus any other implementations needed
   * to satisfy its dependencies.
   * @param dummy_impl adds a lowest-ranked (but valid) implementation to
   *   every interface, so we can always select something. Useful for diagnostics.
   *   You should ensure that [Model.get_command] always returns a dummy command for dummy_impl too.
   *   Note: always try without a [dummy_impl] first, or it may miss a valid solution.
   * @return None if the solve fails (only happens if [closest_match] is false). *)
  val do_solve : ?dummy_impl:Model.impl -> Model.requirements -> selection RoleMap.t option

  (** Request diagnostics-of-last-resort (fallback used when [Diagnostics] can't work out what's wrong).
   * Gets a report from the underlying SAT solver. *)
  val explain : diagnostics -> string
end
