(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
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

(** Ensure all selections are cached, downloading any that are missing.
    If [distro] is given then distribution packages are also installed, otherwise
    they are ignored. *)
let download_selections config (slave:Python.slave) distro sels =
  if Selections.get_unavailable_selections config ?distro sels <> [] then (
    let opts = `Assoc [
      ("include-packages", `Bool (distro <> None));
    ] in

    let request : Yojson.Basic.json = `List [`String "download-selections"; opts] in

    lwt result =
      slave#invoke_async ~xml:sels request (function
        | `List dry_run_paths -> `success (List.map Yojson.Basic.Util.to_string dry_run_paths)
        | `String "aborted-by-user" -> `aborted_by_user
        | json -> raise_safe "Invalid JSON response '%s'" (Yojson.Basic.to_string json)
      ) in

    match result with
    | `aborted_by_user -> Lwt.return `aborted_by_user
    | `success dry_run_paths ->
        (* In --dry-run mode, the directories haven't actually been added, so we need to tell the
         * dryrun_system about them. *)
        if config.dry_run then (
          List.iter (fun name -> config.system#mkdir name 0o755) dry_run_paths
        );
        Lwt.return `success
  ) else (
    Lwt.return `success
  )
