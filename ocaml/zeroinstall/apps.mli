(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Support for 0install apps *)

open General
open Support.Common

type app = filepath

type app_times = {
  last_check_time : float;              (* 0.0 => timestamp missing *)
  last_check_attempt : float option;    (* always > last_check_time, if present *)
  last_solve : float;                   (* 0.0 => timestamp missing *)
}

(** Create a new app with these requirements.
 * You should call [set_selections] immediately after this. *)
val create_app : config -> string -> Requirements.t -> app

(** Remove this app and any shell command created with [integrate_shell]. *)
val destroy : config -> app -> unit

val lookup_app : config -> string -> app option

val get_requirements : system -> app -> Requirements.t
val set_requirements : config -> app -> Requirements.t -> unit

(** Get the dates of the available snapshots, starting with the most recent.
 * Used by the "0install whatchanged" command. *)
val get_history : config -> app -> string list

val get_times : #filesystem -> app -> app_times

(** Get the current selections. Does not check whether they're still valid.
 * @raise Safe_exception if they're missing. *)
val get_selections_no_updates : #filesystem -> app -> Selections.t

(** Get the current selections.
 * If they're missing or unusable, start a solve to get them.
 * If they're usable but stale, spawn a background update but return immediately. *)
val get_selections_may_update :
  < config : config; distro :
    Distro.t;
    make_fetcher : Progress.watcher -> Fetch.fetcher;
    ui : Ui.ui_handler; ..> ->
  app -> Selections.t Lwt.t

val set_selections : config -> app -> Selections.t -> touch_last_checked:bool -> unit

(** Place an executable in $PATH that will launch this app. *)
val integrate_shell : config -> app -> string -> unit

(** Mark the app as up-to-date. *)
val set_last_checked : system -> app -> unit

val list_app_names : config -> string list
