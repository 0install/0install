(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Provides implementation candidates to the solver. *)

open Support

(** Why we rejected an implementation *)
type rejection_reason

(** Why we picked one implementation over another *)
type preference_reason

val describe_problem : _ Impl.t -> rejection_reason -> string
val describe_preference : preference_reason -> string

type candidates = {
  replacement : Sigs.iface_uri option;
  impls : Impl.generic_implementation list;
  rejects : (Impl.generic_implementation * rejection_reason) list;
  compare : Impl.generic_implementation -> Impl.generic_implementation -> int * preference_reason;
  feed_problems : string list;
}

class type impl_provider =
  object
    (** Return all the implementations of this interface (including from feeds).
        Most preferred implementations should come first. *)
    method get_implementations : Sigs.iface_uri -> source:bool -> candidates

    (** Should the solver consider this dependency? *)
    method is_dep_needed : Impl.dependency -> bool

    method extra_restrictions : Impl.restriction XString.Map.t
  end

class default_impl_provider : General.config -> Feed_provider.feed_provider -> Scope_filter.t -> impl_provider
