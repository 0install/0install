(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common

(* This is the entry-point for the unit-tests; it avoids the exception handling. *)
val main : system -> unit

val start : system -> unit
val start_if_not_windows : system -> unit
