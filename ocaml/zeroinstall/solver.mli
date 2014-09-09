(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Select a compatible set of components to run a program. *)

module Model : sig
  include Solver_types.MODEL with
    type Role.t = General.iface_uri * bool and
    type impl = Impl.generic_implementation

  type rejection

  val id_of_impl : impl -> string
  val version : impl -> Versions.parsed_version
  val string_of_restriction : restriction -> string
  val rejects : t -> Role.t -> (impl * rejection) list
  val describe_problem : impl -> rejection -> string
  val format_machine : impl -> string
  val user_restrictions : t -> Role.t -> restriction option
end

module RoleMap : Map.S with type key = Model.Role.t

type result

val selections : result -> Selections.t

(** Get the impl_provider used for this solve. Useful for diagnostics and in the GUI to list the candidates. *)
val impl_provider : result -> Impl_provider.impl_provider

(** Convert [Requirements.t] to requirements for the solver.
 * This looks at the host system to get some values (whether we have multi-arch support, default CPU and OS). *)
val get_root_requirements : General.config -> Requirements.t -> Impl_provider.scope_filter * Model.requirements

(** Find a set of implementations which satisfy these requirements. Consider using [solve_for] instead.
    @param closest_match adds a lowest-ranked (but valid) implementation to every interface, so we can always
           select something. Useful for diagnostics.
    @return None if the solve fails (only happens if [closest_match] is false. *)
val do_solve : Impl_provider.impl_provider -> Model.requirements -> closest_match:bool -> result option

(** High-level solver interface.
 * Runs [do_solve ~closest_match:false] and reports (true, results) on success.
 * On failure, tries again with [~closest_match:true] and reports (false, results) for diagnostics. *)
val solve_for : General.config -> Feed_provider.feed_provider -> Requirements.t -> bool * result

(* The remaining functions are used to provide diagnostics *)
val get_selected : result -> Model.Role.t -> Impl.generic_implementation option
val raw_selections : result -> Impl.generic_implementation RoleMap.t
val explain : result -> Model.Role.t -> string
val requirements : result -> Model.requirements
val model : result -> Model.t
