(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** This defines what the solver sees (hiding the raw XML, etc). *)

open General

(** We can either be trying to find an implementation, or a command within an implementation.
 * The last component is [true] if we're looking for source. *)
type requirements =
  | ReqCommand of (string * iface_uri * bool)
  | ReqIface of (iface_uri * bool)

module type MODEL = sig
  type t
  type impl
  type command
  type dependency
  type restriction
  type impl_response = {
    replacement : iface_uri option;
    impls : impl list;
  }

  val to_string : impl -> string
  val command_to_string : command -> string

  (* A dummy implementation, used to get diagnostic information if the solve fails. It satisfies all requirements,
     even conflicting ones. *)
  val dummy_impl : impl

  (** A fake <command> used to generate diagnostics if the solve fails. *)
  val dummy_command : command

  val get_command : impl -> string -> command option
  val requires : t -> impl -> dependency list
  val command_requires : t -> command -> dependency list
  val to_selection : t -> iface_uri -> string list -> impl -> Support.Qdom.element
  val machine : impl -> string option
  val restrictions : dependency -> restriction list
  val meets_restriction : impl -> restriction -> bool
  val dep_iface : dependency -> iface_uri
  val dep_required_commands : dependency -> string list
  val dep_essential : dependency -> bool
  val implementations : t -> iface_uri -> source:bool -> impl_response

  (** An implementation can bind to itself. e.g. "test" command that requires its own "run" command.
   * Get all such command names. *)
  val impl_self_commands : impl -> string list
  val command_self_commands : command -> string list
  val restricts_only : dependency -> bool
end
