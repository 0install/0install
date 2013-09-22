(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** High-level helper functions *)

open General
open Support.Common
module Basedir = Support.Basedir
module FeedAttr = Constants.FeedAttr
module R = Requirements
module U = Support.Utils
module Q = Support.Qdom

type select_mode = [
  | `Select_only       (* only download feeds, not archives; display "Select" in GUI *)
  | `Download_only     (* download archives too; refresh if stale feeds; display "Download" in GUI *)
  | `Select_for_run    (* download archives; update stale in background; display "Run" in GUI *)
  | `Select_for_update (* like Download_only, but save changes to apps *)
]

(** Ensure all selections are cached, downloading any that are missing. *)
let download_selections ~include_packages ~feed_provider (driver:Driver.driver) sels =
  match Lwt_main.run @@ driver#download_selections ~include_packages ~feed_provider sels with
  | `success -> ()
  | `aborted_by_user -> raise_safe "Aborted by user"

(** Get some selectsions for these requirements.
    Returns [None] if the user cancels.
    @raise Safe_exception if the solve fails. *)
let solve_and_download_impls (driver:Driver.driver) ?test_callback reqs mode ~refresh ~use_gui =
  let config = driver#config in
  let use_gui =
    match use_gui, config.dry_run with
    | Yes, true -> raise_safe "Can't use GUI with --dry-run"
    | (Maybe|No), true -> No
    | use_gui, false -> use_gui in

  let solve_without_gui () =
    let result = driver#solve_with_downloads reqs ~force:refresh ~update_local:refresh in
    match result with
    | (false, result, _) -> raise_safe "%s" (Diagnostics.get_failure_reason config result)
    | (true, result, feed_provider) ->
        let sels = result#get_selections in
        let () =
          match mode with
          | `Select_only -> ()
          | `Download_only | `Select_for_run ->
              download_selections driver ~feed_provider ~include_packages:true sels in
        Some sels in

  match Gui.get_selections_gui driver ?test_callback mode reqs ~refresh ~use_gui with
  | `Success sels -> Some sels
  | `Aborted_by_user -> None
  | `Dont_use_GUI -> solve_without_gui ()
