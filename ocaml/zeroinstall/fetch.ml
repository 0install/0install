(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common

class fetcher (slave:Python.slave) =
  object
    method download_and_import_feed url : [`aborted_by_user | `success ] Lwt.t =
      let request = `List [`String "download-and-import-feed"; `String url] in
      let parse_result = function
        | `String "success" -> `success
        | `String "aborted-by-user" -> `aborted_by_user
        | _ -> raise_safe "Invalid JSON response" in
      slave#invoke_async request parse_result
  end
