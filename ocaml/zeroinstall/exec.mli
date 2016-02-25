(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Executing a selections document *)

open General

(** Calculate the arguments and environment to pass to exec to run this
    process. This also ensures any necessary launchers exist, creating them
    if not. *)
val get_exec_args : config -> ?main:string -> Selections.t -> string list -> (string list * string array)

(** Run the given selections. If [wrapper] is given, run that command with the command we would have run as the arguments.
    If [exec] is given, use that instead of config.system#exec. *)
val execute_selections :
  config ->
  ?exec:(string list -> env:string array -> 'a) ->
  ?wrapper:string ->
  ?main:string ->
  Selections.t ->
  string list ->
  [ `Dry_run of string | `Ok of 'a ]
