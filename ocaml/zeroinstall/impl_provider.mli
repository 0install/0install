(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Provides implementation candidates to the solver. *)

type rejection = [
  | `User_restriction_rejects of Impl.restriction
  | `Poor_stability
  | `No_retrieval_methods
  | `Not_cached_and_offline
  | `Missing_local_impl of Support.Common.filepath
  | `Incompatible_OS
  | `Not_binary
  | `Not_source
  | `Incompatible_machine
]

type acceptability = [
  | `Acceptable
  | rejection
]

(** Why did we pick one version over another? *)
type preferred_reason =
    PreferAvailable
  | PreferDistro
  | PreferID
  | PreferLang
  | PreferMachine
  | PreferNonRoot
  | PreferOS
  | PreferStability
  | PreferVersion

val describe_problem : _ Impl.t -> rejection -> string

type scope_filter = {
  extra_restrictions : Impl.restriction Support.Common.StringMap.t;
  os_ranks : int Support.Common.StringMap.t;
  machine_ranks : int Support.Common.StringMap.t;
  languages : int Support.Locale.LangMap.t;
  allowed_uses : Support.Common.StringSet.t;
  autocompile : bool;
}

type candidates = {
  replacement : General.iface_uri option;
  impls : Impl.generic_implementation list;
  rejects : (Impl.generic_implementation * rejection) list;
  compare : Impl.generic_implementation -> Impl.generic_implementation -> int * preferred_reason;
}

class type impl_provider =
  object
    (** Return all the implementations of this interface (including from feeds).
        Most preferred implementations should come first. *)
    method get_implementations : General.iface_uri -> source:bool -> candidates

    (** Should the solver consider this dependency? *)
    method is_dep_needed : Impl.dependency -> bool

    method extra_restrictions : Impl.restriction Support.Common.StringMap.t
  end

class default_impl_provider : General.config -> Feed_provider.feed_provider -> scope_filter -> impl_provider
