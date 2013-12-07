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
]

(** Ensure all selections are cached, downloading any that are missing. *)
let download_selections ~include_packages ~feed_provider (driver:Driver.driver) sels =
  match_lwt driver#download_selections ~include_packages ~feed_provider sels with
  | `success -> Lwt.return ()
  | `aborted_by_user -> raise_safe "Aborted by user"

let solve_and_download_impls gui (driver:Driver.driver) ?test_callback reqs mode ~refresh =
  let config = driver#config in

  match gui with
  | Gui.Gui gui ->
      begin match_lwt gui#run_solver driver ?test_callback mode reqs ~refresh with
      | `Success sels -> Lwt.return (Some sels)
      | `Aborted_by_user -> Lwt.return None end;
  | Gui.Ui _ ->
      lwt result = driver#solve_with_downloads reqs ~force:refresh ~update_local:refresh in
      match result with
      | (false, result, _) -> raise_safe "%s" (Diagnostics.get_failure_reason config result)
      | (true, result, feed_provider) ->
          let sels = result#get_selections in
          lwt () =
            match mode with
            | `Select_only -> Lwt.return ()
            | `Download_only | `Select_for_run ->
                download_selections driver ~feed_provider ~include_packages:true sels in
          Lwt.return (Some sels)

let make_ui config use_gui : Gui.ui_type =
  let use_gui =
    match use_gui, config.dry_run with
    | Yes, true -> raise_safe "Can't use GUI with --dry-run"
    | (Maybe|No), true -> No
    | use_gui, false -> use_gui in

  let make_no_gui () =
    if config.system#isatty Unix.stderr then
      new Ui.console_ui
    else
      new Ui.batch_ui in

  match use_gui with
  | No -> Gui.Ui (make_no_gui ())
  | Yes | Maybe ->
      (* [try_get_gui] will throw if use_gui is [Yes] and the GUI isn't available *)
      match Gui.try_get_gui config ~use_gui with
      | None -> Gui.Ui (make_no_gui ())
      | Some gui -> Gui.Gui gui
