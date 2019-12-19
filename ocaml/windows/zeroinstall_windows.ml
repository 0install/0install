(* Copyright (C) 2019, Thomas Leonard
   See the README file for details, or visit http://0install.net. *)

type wow =
  | KEY_WOW64_NONE  (* 0 *)
  | KEY_WOW64_32KEY (* 1 *)
  | KEY_WOW64_64KEY (* 2 *)

let () = ignore Callback.register

external win_get_appdata : unit -> string = "caml_win_get_appdata"
external win_get_local_appdata : unit -> string = "caml_win_get_local_appdata"
external win_get_common_appdata : unit -> string = "caml_win_get_common_appdata"
external win_read_registry_string : string -> string -> wow -> string = "caml_win_read_registry_string"
external win_read_registry_int : string -> string -> wow -> int = "caml_win_read_registry_int"
