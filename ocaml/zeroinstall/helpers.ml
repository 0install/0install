(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** High-level helper functions *)

open General
open Support.Common
module Basedir = Support.Basedir
module R = Requirements
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

(** Run the GUI to choose and download a set of implementations
 * If [use_gui] is No; just returns `Dont_use_GUI. 
 * If Maybe, uses the GUI if possible.
 * If Yes, uses the GUI or throws an exception. *)
let get_selections_gui config (slave:Python.slave) ?(systray=false) mode reqs ~refresh ~use_gui =
  if use_gui = No then `Dont_use_GUI
  else if config.dry_run then (
    if use_gui = Maybe then `Dont_use_GUI
    else raise_safe "Can't use GUI with --dry-run"
  ) else if config.system#getenv "DISPLAY" = None then (
    if use_gui = Maybe then `Dont_use_GUI
    else raise_safe "Can't use GUI because $DISPLAY is not set"
  ) else if not (slave#invoke (`List [`String "check-gui"; `String (string_of_ynm use_gui)]) Yojson.Basic.Util.to_bool) then (
    `Dont_use_GUI       (* [check-gui] will throw if use_gui is [Yes] *)
  ) else (
    let action = match mode with
    | Select_only -> "for-select"
    | Download_only | Select_for_update -> "for-download"
    | Select_for_run -> "for-run" in

    let opts = `Assoc [
      ("refresh", `Bool refresh);
      ("action", `String action);
      ("use_gui", `String (string_of_ynm use_gui));
      ("systray", `Bool systray);
    ] in

    slave#invoke (`List [`String "get-selections-gui"; R.to_json reqs; opts]) (function
      | `List [`String "ok"; `String xml] -> `Success (Q.parse_input None @@ Xmlm.make_input @@ `String (0, xml))
      | `List [`String "dont-use-gui"] -> `Dont_use_GUI
      | `List [`String "aborted-by-user"] -> `Aborted_by_user
      | json -> raise_safe "Invalid JSON response: %s" (Yojson.Basic.to_string json)
    )
  )

(** Get some selectsions for these requirements.
    Returns [None] if the user cancels.
    @raise Safe_exception if the solve fails. *)
let solve_and_download_impls config distro (slave:Python.slave) reqs mode ~refresh ~use_gui =
  let use_gui =
    match use_gui, config.dry_run with
    | Yes, true -> raise_safe "Can't use GUI with --dry-run"
    | (Maybe|No), true -> No
    | use_gui, false -> use_gui in

  let solve_without_gui () =
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
        Some sels in

  match get_selections_gui config slave mode reqs ~refresh ~use_gui with
  | `Success sels -> Some sels
  | `Aborted_by_user -> None
  | `Dont_use_GUI -> solve_without_gui ()
