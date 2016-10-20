(* Copyright (C) 2016, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The global preferences dialog. *)

open Zeroinstall

val make :
  General.config ->
  Trust.trust_db ->
  recalculate:(unit -> unit) ->
  GWindow.window_skel * unit Lwt.t
