(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** This is the part of the Windows support code that is always linked in. In the portable bytecode,
    it must not actually depend on any Windows functions directly. It just defines the API that Windows
    should provide and allows windows.ml to register the real implementation at runtime, if we happen
    to be on Windows. *)

Callback.register

type wow =
  | KEY_WOW64_NONE  (* 0 *)
  | KEY_WOW64_32KEY (* 1 *)
  | KEY_WOW64_64KEY (* 2 *)

class type windows_api =
  object
    method get_appdata : unit -> string
    method get_local_appdata : unit -> string
    method get_common_appdata : unit -> string
    method read_registry_string : string -> string -> wow -> string option  (* Reads from HKEY_LOCAL_MACHINE *)
    method read_registry_int : string -> string -> wow -> int option        (* Reads from HKEY_LOCAL_MACHINE *)
  end

let windowsAPI : windows_api option ref = ref None

#ifdef WINDOWS
  (* This is only used when compiling native code on Windows, not for the portable bytecode. *)
  external win_get_appdata : unit -> string = "caml_win_get_appdata"
  external win_get_local_appdata : unit -> string = "caml_win_get_local_appdata"
  external win_get_common_appdata : unit -> string = "caml_win_get_common_appdata"
  external win_read_registry_string : string -> string -> wow -> string = "caml_win_read_registry_string"
  external win_read_registry_int : string -> string -> wow -> int = "caml_win_read_registry_int"

  windowsAPI := Some (
    object
      method get_appdata = win_get_appdata
      method get_local_appdata = win_get_local_appdata
      method get_common_appdata = win_get_common_appdata
      method read_registry_string key value wow =
        try Some (win_read_registry_string key value wow)
        with Failure msg ->
          Common.log_debug "Error getting registry value %s:%s: %s" key value msg;
          None
      method read_registry_int key value wow =
        try Some (win_read_registry_int key value wow)
        with Failure msg ->
          Common.log_debug "Error getting registry value %s:%s: %s" key value msg;
          None
    end
  )
#endif
