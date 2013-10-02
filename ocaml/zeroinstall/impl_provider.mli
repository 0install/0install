(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Provides implementation candidates to the solver. *)

type rejection = [
  | `User_restriction_rejects of Feed.restriction
  | `Poor_stability
  | `No_retrieval_methods
  | `Not_cached_and_offline
  | `Missing_local_impl
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

val describe_problem : Feed.implementation -> rejection -> string

type scope_filter = {
  extra_restrictions : Feed.restriction Support.Common.StringMap.t;
  os_ranks : int Support.Common.StringMap.t;
  machine_ranks : int Support.Common.StringMap.t;
  languages : int Support.Locale.LangMap.t;
  allowed_uses : Support.Common.StringSet.t;
}

type candidates = {
  replacement : General.iface_uri option;
  impls : Feed.implementation list;
  rejects : (Feed.implementation * rejection) list;
}

class type impl_provider =
  object
    (** Return all the implementations of this interface (including from feeds).
        Most preferred implementations should come first. *)
    method get_implementations : General.iface_uri -> source:bool -> candidates

    (** Should the solver consider this dependency? *)
    method is_dep_needed : Feed.dependency -> bool

    method extra_restrictions : Feed.restriction Support.Common.StringMap.t
  end

class default_impl_provider : General.config -> Feed_provider.feed_provider -> scope_filter ->
  object
    method extra_restrictions : Feed.restriction Support.Common.StringMap.t
    method get_implementations : General.iface_uri -> source:bool -> candidates
    method is_dep_needed : Feed.dependency -> bool

    method set_watch_iface : General.iface_uri -> unit
    method get_watched_compare : (Feed.implementation -> Feed.implementation -> int * preferred_reason) option
  end
