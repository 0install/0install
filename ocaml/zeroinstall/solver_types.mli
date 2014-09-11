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

  val impl_to_string : impl -> string
  val command_to_string : command -> string

  (** The list of candidates to fill a role. *)
  val implementations : t -> Role.t -> role_information

  val get_command : impl -> command_name -> command option

  (** Get an implementation's dependencies.
   *
   * The dependencies should be ordered with the most important first.
   * The solver will prefer to select the best possible version of an earlier
   * dependency, even if that means selecting a worse version of a later one
   * ([restricts_only] dependencies are ignored for this).
   *
   * An implementation or command can also bind to itself.
   * e.g. "test" command that requires its own "run" command.
   * We also return all such required commands. *)
  val requires : t -> impl -> dependency list * command_name list

  (** As [requires], but for commands. *)
  val command_requires : t -> command -> dependency list * command_name list

  val machine : impl -> Arch.machine_group option
  val meets_restriction : impl -> restriction -> bool

  type requirements =
    | ReqCommand of (command_name * Role.t)
    | ReqRole of Role.t

  (* A dummy implementation, used to get diagnostic information if the solve fails.
   * It satisfies all requirements, even conflicting ones. *)
  val dummy_impl : impl

  (** A fake <command> used to generate diagnostics if the solve fails. *)
  val dummy_command : command
end

module type DIAGNOSTICS = sig
  (** Used to provide diagnostics *)

  include MODEL

  (** The solution produced by the solver (or its best attempt at one) *)
  type result

  (** The reason why the model rejected an implementation before it got to the solver. *)
  type rejection

  (** Get the candidates which were rejected for a role (and not passed to the solver). *)
  val rejects : t -> Role.t -> (impl * rejection) list

  (** A version number. Used for display and sorting the results. *)
  type version
  val version : impl -> version
  val format_version : version -> string

  (** Get any user-specified restrictions affecting a role.
   * These are used to filter out implementations before they get to the solver. *)
  val user_restrictions : t -> Role.t -> restriction option

  module RoleMap : Map.S with type key = Role.t

  val id_of_impl : impl -> string
  val format_machine : impl -> string
  val string_of_restriction : restriction -> string
  val describe_problem : impl -> rejection -> string

  val get_selected : result -> Role.t -> impl option

  (** Get the final assignment of implementations to roles. *)
  val raw_selections : result -> impl RoleMap.t

  (** Get diagnostics-of-last-resort. *)
  val explain : result -> Role.t -> string

  val requirements : result -> requirements
  val model : result -> t
end
