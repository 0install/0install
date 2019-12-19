(* Copyright (C) 2019, Thomas Leonard
   See the README file for details, or visit http://0install.net. *)

type wow = Zeroinstall_windows.wow =
  | KEY_WOW64_NONE
  | KEY_WOW64_32KEY
  | KEY_WOW64_64KEY

class type windows_api =
  object
    method get_appdata : unit -> string
    method get_local_appdata : unit -> string
    method get_common_appdata : unit -> string
    method read_registry_string : string -> string -> wow -> string option  (* Reads from HKEY_LOCAL_MACHINE *)
    method read_registry_int : string -> string -> wow -> int option        (* Reads from HKEY_LOCAL_MACHINE *)
  end

open Zeroinstall_windows

let windowsAPI : windows_api option ref = ref (Some (
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
  ))
