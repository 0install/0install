(* Copyright (C) 2018, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** <command> elements *)

open Support
open Support.Common

(** [build_command sels reqs env] is the argv for the command to run to execute [sels] as requested by [reqs].
    In --dry-run mode, don't complain if the target doesn't exist. *)
val build_command :
  ?main:string ->
  ?dry_run:bool ->
  (Selections.impl * filepath option) Selections.RoleMap.t ->
  Selections.requirements ->
  Env.t ->
  string list
