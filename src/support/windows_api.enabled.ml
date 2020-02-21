(* Copyright (C) 2019, Thomas Leonard
   See the README file for details, or visit http://0install.net. *)

module W = Zeroinstall_windows

let v ~wow64 =
  let read_registry fn key value ~key64 =
    try
      match wow64, key64 with
      | true, false -> Some (fn key value W.KEY_WOW64_32KEY)
      | true, true -> Some (fn key value W.KEY_WOW64_64KEY)
      | false, false -> Some (fn key value W.KEY_WOW64_NONE)
      | false, true -> None
    with Failure msg ->
      Logging.log_debug "Error getting registry value %s:%s: %s" key value msg;
      None
  in
  object
    method get_appdata = W.win_get_appdata ()
    method get_local_appdata = W.win_get_local_appdata ()
    method get_common_appdata = W.win_get_common_appdata ()
    method read_registry_string = read_registry W.win_read_registry_string
    method read_registry_int = read_registry W.win_read_registry_int
  end
