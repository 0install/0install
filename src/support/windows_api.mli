(* Copyright (C) 2019, Thomas Leonard
   See the README file for details, or visit http://0install.net. *)

val v : wow64:bool -> Common.windows_api
(** [v ~wow] is an object for interacting with Windows.
    Raises an exception if the host system is not Windows.
    @param wow64 This is a 64-bit system - use [KEY_WOW64_32KEY], etc. *)
