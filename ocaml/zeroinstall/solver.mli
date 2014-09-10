(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Select a compatible set of components to run a program. *)

(** We can either be trying to find an implementation, or a command within an implementation.
 * The last component is [true] if we're looking for source. *)
type requirements =
  | ReqCommand of (string * General.iface_uri * bool)
  | ReqIface of (General.iface_uri * bool)

module Model : Solver_types.MODEL with
 type Role.t = General.iface_uri * bool

module RoleMap : Map.S with type key = Model.Role.t

class type result =
  object
    method get_selections : Selections.t

    (* The remaining methods are used to provide diagnostics *)
    method get_selected : source:bool -> General.iface_uri -> Impl.generic_implementation option
    method impl_provider : Impl_provider.impl_provider
    method raw_selections : Impl.generic_implementation RoleMap.t
    method explain : Model.Role.t -> string
    method requirements : requirements
  end

(** Convert [Requirements.t] to requirements for the solver.
 * This looks at the host system to get some values (whether we have multi-arch support, default CPU and OS). *)
val get_root_requirements : General.config -> Requirements.t -> Impl_provider.scope_filter * requirements

(** Find a set of implementations which satisfy these requirements. Consider using [solve_for] instead.
    @param closest_match adds a lowest-ranked (but valid) implementation to every interface, so we can always
           select something. Useful for diagnostics.
    @return None if the solve fails (only happens if [closest_match] is false. *)
val do_solve : Impl_provider.impl_provider -> requirements -> closest_match:bool -> result option

(** High-level solver interface.
 * Runs [do_solve ~closest_match:false] and reports (true, results) on success.
 * On failure, tries again with [~closest_match:true] and reports (false, results) for diagnostics. *)
val solve_for : General.config -> Feed_provider.feed_provider -> Requirements.t -> bool * result
