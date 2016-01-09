(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Some useful abstract module types. *)

open Support.Common

module type MAP = sig
  include Map.S

  (** Safe version of [find] that returns an option. *)
  val find : key -> 'a t -> 'a option
end

module type CORE_MODEL = sig
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

  (** An identifier for a command within a role. *)
  type command_name = private string

  (** A dependency indicates that an impl or command requires another role to be filled. *)
  type dependency

  type dep_info = {
    dep_role : Role.t;

    (* If the dependency is [`essential] then its role must be filled.
     * Otherwise, we just prefer to fill it if possible.
     * A [`restricts] dependency does not cause the solver to try to fill a role, it just
     * adds restrictions if it is used for some other reason. *)
    dep_importance : [ `essential | `recommended | `restricts ];

    (* Any commands on [dep_role] required by this dependency. *)
    dep_required_commands : command_name list;
  }

  type requirements = {
    role : Role.t;
    command : command_name option;
  }

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
  val requires : Role.t -> impl -> dependency list * command_name list

  val dep_info : dependency -> dep_info

  (** As [requires], but for commands. *)
  val command_requires : Role.t -> command -> dependency list * command_name list

  val get_command : impl -> command_name -> command option
end

module type SOLVER_INPUT = sig
  (** This defines what the solver sees (hiding the raw XML, etc). *)

  include CORE_MODEL

  (** Information provided to the solver about a role. *)
  type role_information = {
    replacement : Role.t option;  (** Another role that conflicts with this one. *)
    impls : impl list;            (** Candidates to fill the role. *)
  }

  (** A restriction limits which implementations can fill a role. *)
  type restriction

  val impl_to_string : impl -> string
  val command_to_string : command -> string

  (** The list of candidates to fill a role. *)
  val implementations : Role.t -> role_information

  (** Restrictions on how the role is filled *)
  val restrictions : dependency -> restriction list
  val meets_restriction : impl -> restriction -> bool

  val machine_group : impl -> Arch.machine_group option
end

module type SELECTIONS = sig
  (** Some selections previously produced by a solver. *)

  include CORE_MODEL

  type t

  val get_selected : Role.t -> t -> impl option
  val selected_commands : t -> Role.t -> command_name list
  val requirements : t -> requirements

  module RoleMap : MAP with type key = Role.t
end

module type SOLVER_RESULT = sig
  (** The result of running the solver.
   * Unlike the plain [SELECTIONS] type, this type can relate the selections back
   * to the solver inputs, which is useful to provide diagnostics and the GUI. *)

  include SOLVER_INPUT
  include SELECTIONS with
    module Role := Role and
    type impl := impl and
    type command := command and
    type dependency := dependency and
    type command_name := command_name and
    type dep_info := dep_info and
    type requirements := requirements

  (** The reason why the model rejected an implementation before it got to the solver. *)
  type rejection

  (** Get the candidates which were rejected for a role (and not passed to the solver),
   * as well as any general notes and warnings not tied to a particular impl. *)
  val rejects : Role.t -> (impl * rejection) list * string list

  (** Used to sort the results. *)
  val compare_version : impl -> impl -> int
  val format_version : impl -> string

  (** Get any user-specified restrictions affecting a role.
   * These are used to filter out implementations before they get to the solver. *)
  val user_restrictions : Role.t -> restriction option

  val id_of_impl : impl -> string
  val format_machine : impl -> string
  val string_of_restriction : restriction -> string
  val describe_problem : impl -> rejection -> string

  (** Get diagnostics-of-last-resort. *)
  val explain : t -> Role.t -> string

  (** Get the final assignment of implementations to roles. *)
  val raw_selections : t -> impl RoleMap.t

  (* A dummy implementation, used to get diagnostic information if the solve fails.
   * It satisfies all requirements, even conflicting ones. *)
  val dummy_impl : impl
end

module type SEARCH_PATH = sig
  type config
  type key

  val all_paths : key -> config -> filepath list
  (** [all_paths key config] is all the existing paths for [key], in search order. *)

  val first : key -> config -> filepath option
  (** [first key config] is the first existing path of [key] in the search path. *)

  val save_path : key -> config -> filepath
  (** [save_path key config] creates a directory for [key] in the first directory in
      the search path (if it doesn't yet exist) and returns the path of the
      [key] within it (which may not yet exist). *)

  val ( // ) : key -> string -> key
  (** [key // sub] is a sub-directory or file under [key]. *)
end
