(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Select a compatible set of components to run a program. *)

module Make : functor (Model : Solver_types.MODEL) -> sig
  type diagnostics

  module RoleMap : Map.S with type key = Model.Role.t

  class type result =
    object
      method get_selections : Model.impl RoleMap.t
      method get_commands_needed : Model.Role.t -> Model.command_name list

      (* The remaining methods are used to provide diagnostics *)
      method get_selected : Model.Role.t -> Model.impl option
      method implementations : (Model.Role.t * (diagnostics * Model.impl) option) list
    end

  (** [do_solve model role] finds an implementation for the given role, plus any other implementations needed
   * to satisfy its dependencies.
   * @param command can be used to require a particular command
   * @param closest_match adds a lowest-ranked (but valid) implementation to
   *   every interface, so we can always select something. Useful for diagnostics.
   * @return None if the solve fails (only happens if [closest_match] is false. *)
  val do_solve : Model.t -> Model.Role.t -> ?command:Model.command_name -> closest_match:bool -> result option

  (** Request diagnostics-of-last-resort (fallback used when [Diagnostics] can't work out what's wrong).
   * Gets a report from the underlying SAT solver. *)
  val explain : diagnostics -> string
end
