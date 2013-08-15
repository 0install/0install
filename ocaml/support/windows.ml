(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* These C functions are only available on Windows, so we have to dynamically link this module to
   avoid errors on other systems. *)

external win_get_appdata : unit -> string = "caml_win_get_appdata"
external win_get_local_appdata : unit -> string = "caml_win_get_local_appdata"
external win_get_common_appdata : unit -> string = "caml_win_get_common_appdata"

let api =
  object
    method get_appdata = win_get_appdata
    method get_local_appdata = win_get_local_appdata
    method get_common_appdata = win_get_common_appdata
  end
