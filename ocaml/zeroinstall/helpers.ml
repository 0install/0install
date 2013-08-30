(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** High-level helper functions *)

open Support.Common
module Basedir = Support.Basedir
module U = Support.Utils
module Q = Support.Qdom

type select_mode =
  | Select_only       (* only download feeds, not archives; display "Select" in GUI *)
  | Download_only     (* download archives too; refresh if stale feeds; display "Download" in GUI *)
  | Select_for_run    (* download archives; update stale in background; display "Run" in GUI *)
  | Select_for_update (* like Download_only, but save changes to apps *)

let string_of_ynm = function
  | Yes -> "yes"
  | No -> "no"
  | Maybe -> "maybe"

(** Ensure all selections are cached, downloading any that are missing.
    If [distro] is given then distribution packages are also installed, otherwise
    they are ignored. *)
let download_selections config (slave:Python.slave) distro sels =
  if Selections.get_unavailable_selections config ?distro sels <> [] then (
    let opts = `Assoc [
      ("include-packages", `Bool (distro <> None));
    ] in

    let request : Yojson.Basic.json = `List [`String "download-selections"; opts] in

    slave#invoke ~xml:sels request ignore
  )

(** Get some selectsions for these requirements.
    Returns [None] if the user cancels.
    @raise Safe_exception if the solve fails. *)
let solve_and_download_impls config distro (slave:Python.slave) reqs mode ~refresh ~use_gui =
  if use_gui = No then (
    let fetcher = new Fetch.fetcher slave in
    let result = Driver.solve_with_downloads config fetcher distro reqs ~force:refresh ~update_local:refresh in
    match result with
    | (false, result) -> raise_safe "%s" (Diagnostics.get_failure_reason config result)
    | (true, result) ->
        let sels = result#get_selections in
        let () =
          match mode with
          | Select_only -> ()
          | Download_only | Select_for_update | Select_for_run ->
              download_selections config slave (Some distro) sels in
        Some sels
  ) else (
    let action = match mode with
    | Select_only -> "for-select"
    | Download_only | Select_for_update -> "for-download"
    | Select_for_run -> "for-run" in

    let opts = `Assoc [
      ("refresh", `Bool refresh);
      ("use_gui", `String (string_of_ynm use_gui));
    ] in

    let read_xml = function
      | `String "Aborted" -> None
      | `String s -> Some (Q.parse_input None @@ Xmlm.make_input (`String (0, s)))
      | _ -> raise_safe "Invalid response" in
    let request : Yojson.Basic.json = `List [`String "select"; `String action; opts; Requirements.to_json reqs] in

    slave#invoke request read_xml
  )
