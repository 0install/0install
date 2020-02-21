(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** OS and CPU types. *)

open Support
open Support.Common

type os
type machine
type arch = os option * machine option

type os_ranking
type machine_ranking

(** Parse a (canonical) arch, as found in 0install feeds. *)
val parse_arch : string -> arch

val format_arch : arch -> string

val get_os_ranks : os -> os_ranking

(** Treat a string as a machine type. None if "*". *)
val parse_machine : string -> machine option

val parse_os : string -> os option

type machine_group =
  | Machine_group_default     (* e.g. i686 *)
  | Machine_group_64          (* e.g. x86_64 *)

(* All chosen machine-specific implementations must come from the same group.
   Unlisted archs are in Machine_group_default. *)
val get_machine_group : machine option -> machine_group option

val get_machine_ranks : multiarch:bool -> machine -> machine_ranking

(** Is this value in the ranking? *)
val os_ok : os_ranking -> os option -> bool
val machine_ok : machine_ranking -> machine option -> bool

val os_rank : os_ranking -> os -> int option
val machine_rank : machine_ranking -> machine -> int option

val format_machine : machine -> string
val format_os : os -> string

(** Returns "*" if None. *)
val format_machine_or_star : machine option -> string

(** Returns "*" if None. *)
val format_os_or_star : os option -> string

val is_src : machine option -> bool

val platform : system -> os * machine

val linux : os
val x86_64 : machine

val custom_os_ranking : int XString.Map.t -> os_ranking
val custom_machine_ranking : int XString.Map.t -> machine_ranking
