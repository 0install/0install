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
module Diagnostics(Result : S.SOLVER_RESULT) : sig

  (** An item of information to display for a component. *)
  module Note : sig
    type rejection_reason = [
      | `Model_rejection of Result.Input.rejection
      | `FailsRestriction of Result.Input.restriction
      | `DepFailsRestriction of Result.Input.dependency * Result.Input.restriction
      | `MachineGroupConflict of Result.Role.t * Result.Input.impl
      | `ClassConflict of Result.Role.t * Result.Input.conflict_class
      | `ConflictsRole of Result.Role.t
      | `MissingCommand of Result.Input.command_name
      | `DiagnosticsFailure of string
    ]
    (** Why a particular implementation was rejected. This could be because the
        input rejected it before it got to the solver, or because it conflicts
        with something else in the example (partial) solution. *)

    type t =
      | UserRequested of Result.Input.restriction
      | ReplacesConflict of Result.Role.t
      | ReplacedByConflict of Result.Role.t
      | Restricts of Result.Role.t * Result.Input.impl * Result.Input.restriction list
      | RequiresCommand of Result.Role.t * Result.Input.impl * Result.Input.command_name
      | Feed_problem of string
      | NoCandidates of {
          reason : [`No_candidates | `No_usable_candidates | `Rejected_candidates];
          rejects : (Result.Input.impl * rejection_reason) list;
        }

    val pp : verbose:bool -> Format.formatter -> t -> unit
    (** [pp_note ~verbose] is a formatter for notes.
        @param verbose If [false], limit the list of rejected candidates (if any) to five entries. *)
  end

  (** Information about a single role in the example (failed) selections produced by the solver. *)
  module Component : sig
    type t

    val selected_impl : t -> Result.Input.impl option
    (** [selected_impl t] is the implementation selected to fill [t]'s role, or
        [None] if no implementation was suitable. *)

    val notes : t -> Note.t list
    (** Information discovered about this component. *)

    val pp : verbose:bool -> Format.formatter -> t -> unit
    (** [pp ~verbose] formats a message showing the status of this component,
        including all of its notes. *)
  end

  type t = Component.t Result.RoleMap.t
  (** An analysis of why the solve failed. *)

  val of_result : Result.t -> t
  (** [of_result r] is an analysis of failed solver result [r].
      We take the partial solution from the solver and discover, for each
      component we couldn't select, which constraints caused the candidates to
      be rejected. *)

  val get_failure_reason : ?verbose:bool -> Result.t -> string
  (** [get_failure_reason r] analyses [r] with [of_result] and formats the
      analysis as a string. *)
end

(** The low-level SAT solver. *)
module Sat = Sat
