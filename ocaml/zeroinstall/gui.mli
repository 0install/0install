(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Manage the GUI sub-process. *)

val get_selections_gui :
  Driver.driver ->
  ?test_callback:(Support.Qdom.element -> string Lwt.t) ->
  ?systray:bool ->
  [< `Download_only | `Select_for_run | `Select_only ] ->
  Requirements.requirements ->
  refresh:bool ->
  [> `Aborted_by_user | `Success of Support.Qdom.element ]
