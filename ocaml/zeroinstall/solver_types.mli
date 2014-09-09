(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** This defines what the solver sees (hiding the raw XML, etc). *)

module type MODEL = sig
  type t

  module Role : sig
    (** A role that needs to be filled by a single implementation.
     * If two dependencies require the same role then they will both
     * get the same implementation. *)
    type t
    val to_string : t -> string
    val compare : t -> t -> int
  end

  (** An [impl] is something that can fill a [Role.t] *)
  type impl

  (** A [command] is an entry-point provided by an implementation.
   * Using a command may require extra dependencies (for example, a "test" command
   * might depend on a test runner). *)
  type command

  (** A restriction limits which implementations can fill a role. *)
  type restriction

  (** An identifier for a command within a role. *)
  type command_name = private string

  (** A dependency indicates that an impl or command requires another role to be filled. *)
  type dependency = {
    dep_role : Role.t;
    dep_restrictions : restriction list;    (** Restrictions on how the role is filled *)

    (** If the dependency is [`essential] then its role must be filled.
     * Otherwise, we just prefer to fill it if possible.
     * A [`restricts] dependency does not cause the solver to try to fill a role, it just
     * adds restrictions if it is used for some other reason. *)
    dep_importance : [ `essential | `recommended | `restricts ];

    (** Any commands on [dep_role] required by this dependency. *)
    dep_required_commands : command_name list;
  }

  (** Information provided to the solver about a role. *)
  type role_information = {
    replacement : Role.t option;  (** Another role that conflicts with this one. *)
    impls : impl list;            (** Candidates to fill the role. *)
  }

  val to_string : impl -> string
  val command_to_string : command -> string

  (** The list of candidates to fill a role. *)
  val implementations : t -> Role.t -> role_information

  val get_command : impl -> command_name -> command option

  (** Get an implementation's dependencies.
   *
   * The dependencies should be ordered with the most important first.
   * The solver will prefer to select the best possible version of an earlier
   * dependency, even if that means selecting a worse version of a later one
   * ([restricts_only] dependencies are ignored for this). *)
  val requires : t -> impl -> dependency list

  (** As [requires], but for commands. *)
  val command_requires : t -> command -> dependency list

  val machine : impl -> Arch.machine_group option
  val meets_restriction : impl -> restriction -> bool

  (** An implementation can bind to itself. e.g. "test" command that requires its own "run" command.
   * Get all such command names. *)
  val impl_self_commands : impl -> command_name list
  val command_self_commands : command -> command_name list

  (* A dummy implementation, used to get diagnostic information if the solve fails.
   * It satisfies all requirements, even conflicting ones. *)
  val dummy_impl : impl

  (** A fake <command> used to generate diagnostics if the solve fails. *)
  val dummy_command : command
end
