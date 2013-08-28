(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common

class fetcher (slave:Python.slave) =
  object
    method download_and_import_feed url =
      let request = `List [`String "download-and-import-feed"; `String url] in
      let parse_result = function
        | `List [] -> ()
        | _ -> raise_safe "Invalid JSON response" in
      slave#invoke_async request parse_result
  end
