(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Manage the GUI sub-process. *)

val get_selections_gui :
  General.config ->
  Python.slave ->
  ?test_callback:(Support.Qdom.element -> string Lwt.t) ->
  Distro.distribution ->
  ?systray:bool ->
  [< `Download_only | `Select_for_run | `Select_for_update | `Select_only ] ->
  Requirements.requirements ->
  refresh:bool ->
  use_gui:Support.Common.yes_no_maybe ->
  [> `Aborted_by_user | `Dont_use_GUI | `Success of Support.Qdom.element ]
