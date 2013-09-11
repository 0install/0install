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

type select_mode = [
  | `Select_only       (* only download feeds, not archives; display "Select" in GUI *)
  | `Download_only     (* download archives too; refresh if stale feeds; display "Download" in GUI *)
  | `Select_for_run    (* download archives; update stale in background; display "Run" in GUI *)
  | `Select_for_update (* like Download_only, but save changes to apps *)
]

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
let solve_and_download_impls config distro (slave:Python.slave) ?test_callback reqs mode ~refresh ~use_gui =
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
          | `Select_only -> ()
          | `Download_only | `Select_for_update | `Select_for_run ->
              download_selections config slave (Some distro) sels in
        Some sels in

  match Gui.get_selections_gui config slave ?test_callback distro mode reqs ~refresh ~use_gui with
  | `Success sels -> Some sels
  | `Aborted_by_user -> None
  | `Dont_use_GUI -> solve_without_gui ()
