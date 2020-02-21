(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Used for filtering and ranking implementations before passing them to the solver. *)

open Support

type t = {
  extra_restrictions : Impl.restriction XString.Map.t;  (* iface -> test *)
  os_ranks : Arch.os_ranking;
  machine_ranks : Arch.machine_ranking;
  languages : int Support.Locale.LangMap.t;
  allowed_uses : XString.Set.t;                         (* deprecated *)
  may_compile : bool;       (* For each source impl, add the potential binary that could be made from it *)
}

(** Check whether some OS is acceptable.
 * If no particular OS is specified, then any OS will do. *)
val os_ok : t -> Arch.os option -> bool

(** Check whether some machine is acceptable.
 * If no particular machine is specified, then any will do. *)
val machine_ok : t -> want_source:bool -> Arch.machine option -> bool

(** Check whether the language part of a lang_spec is acceptable. *)
val lang_ok : t -> Support.Locale.lang_spec -> bool

(** Check whether a 'use' value is acceptable (deprecated). *)
val use_ok : t -> string option -> bool

(** Get the rank of an OS. Lower numbers are better. *)
val os_rank : t -> Arch.os -> int option

(** Get the rank of a CPU type. Lower numbers are better. *)
val machine_rank : t -> Arch.machine -> int option

(* Rank of this lang_spec (0 if not acceptable). *)
val lang_rank : t -> Support.Locale.lang_spec -> int

(* Get the user-provided restriction for an interface, if any. *)
val user_restriction_for : t -> Sigs.iface_uri -> Impl.restriction option

(* Should we consider this feed import? *)
val use_feed : t -> want_source:bool -> Feed_import.t -> bool
