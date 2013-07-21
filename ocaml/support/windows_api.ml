(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** This is the part of the Windows support code that is always linked in. In the portable bytecode,
    it must not actually depend on any Windows functions directly. It just defines the API that Windows
    should provide and allows windows.ml to register the real implementation at runtime, if we happen
    to be on Windows. *)

Callback.register;;

class type windows_api =
  object
    method get_appdata : unit -> string
    method get_local_appdata : unit -> string
    method get_common_appdata : unit -> string
  end

let windowsAPI : windows_api option ref = ref None

IFDEF WINDOWS THEN
  (* This is only used when compiling native code on Windows, not for the portable bytecode. *)
  external win_get_appdata : unit -> string = "caml_win_get_appdata"
  external win_get_local_appdata : unit -> string = "caml_win_get_local_appdata"
  external win_get_common_appdata : unit -> string = "caml_win_get_common_appdata"

  windowsAPI := Some (
    object
      method get_appdata = win_get_appdata
      method get_local_appdata = win_get_local_appdata
      method get_common_appdata = win_get_common_appdata
    end
  )
ENDIF
