(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Select a compatible set of components to run a program. *)

type diagnostics

(** Request diagnostics-of-last-resort (fallback used when [Diagnostics] can't work out what's wrong).
 * Gets a report from the underlying SAT solver. *)
val explain : diagnostics -> string

class type result =
  object
    method get_selections : Selections.t

    (* The remaining methods are used to provide diagnostics *)
    method get_selected : source:bool -> General.iface_uri -> Impl.generic_implementation option
    method impl_provider : Impl_provider.impl_provider
    method implementations : ((General.iface_uri * bool) * (diagnostics * Impl.generic_implementation) option) list
    method requirements : Solver_types.requirements
  end

(** Convert [Requirements.t] to requirements for the solver.
 * This looks at the host system to get some values (whether we have multi-arch support, default CPU and OS). *)
val get_root_requirements : General.config -> Requirements.t -> Impl_provider.scope_filter * Solver_types.requirements

(** Find a set of implementations which satisfy these requirements. Consider using [solve_for] instead.
    @param closest_match adds a lowest-ranked (but valid) implementation to every interface, so we can always
           select something. Useful for diagnostics.
    @return None if the solve fails (only happens if [closest_match] is false. *)
val do_solve : Impl_provider.impl_provider -> Solver_types.requirements -> closest_match:bool -> result option

(** High-level solver interface.
 * Runs [do_solve ~closest_match:false] and reports (true, results) on success.
 * On failure, tries again with [~closest_match:true] and reports (false, results) for diagnostics. *)
val solve_for : General.config -> Feed_provider.feed_provider -> Requirements.t -> bool * result
