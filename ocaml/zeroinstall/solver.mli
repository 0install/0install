(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Select a compatible set of components to run a program. *)

type scope = Impl_provider.impl_provider
type role = {
  scope : scope;
  iface : General.iface_uri;
  source : bool;
}

module Model : Solver_types.DIAGNOSTICS with
  type Role.t = role and
  type impl = Impl.generic_implementation

val selections : Model.result -> Selections.t

(** Get the impl_provider used for this role. Useful for diagnostics and in the GUI to list the candidates. *)
val impl_provider : role -> Impl_provider.impl_provider

(** Convert [Requirements.t] to requirements for the solver.
 * This looks at the host system to get some values (whether we have multi-arch support, default CPU and OS). *)
val get_root_requirements : General.config -> Requirements.t -> (Impl_provider.scope_filter -> Impl_provider.impl_provider) -> Model.requirements

(** Find a set of implementations which satisfy these requirements. Consider using [solve_for] instead.
    @param closest_match adds a lowest-ranked (but valid) implementation to every interface, so we can always
           select something. Useful for diagnostics.
    @return None if the solve fails (only happens if [closest_match] is false. *)
val do_solve : Model.requirements -> closest_match:bool -> Model.result option

(** High-level solver interface.
 * Runs [do_solve ~closest_match:false] and reports (true, results) on success.
 * On failure, tries again with [~closest_match:true] and reports (false, results) for diagnostics. *)
val solve_for : General.config -> Feed_provider.feed_provider -> Requirements.t -> bool * Model.result

(** Why did this solve fail? We take the partial solution from the solver and show,
    for each component we couldn't select, which constraints caused the candidates
    to be rejected. *)
val get_failure_reason : General.config -> Model.result -> string
