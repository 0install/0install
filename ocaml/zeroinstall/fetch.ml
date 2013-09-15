(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common

module Q = Support.Qdom

class fetcher config (slave:Python.slave) =
  object
    method download_and_import_feed url : [`aborted_by_user | `success of Q.element ] Lwt.t =
      let request = `List [`String "download-and-import-feed"; `String url] in
      let parse_result = function
        | `List [`String "success"; `String xml] ->
            let cache_path = Feed_cache.get_save_cache_path config url in
            `success (Q.parse_input (Some cache_path) (Xmlm.make_input (`String (0, xml))))
        | `String "aborted-by-user" -> `aborted_by_user
        | _ -> raise_safe "Invalid JSON response" in
      slave#invoke_async request parse_result
  end
