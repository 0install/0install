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

let solve_and_download_impls gui (fetcher:_ Fetch.fetcher) ?test_callback reqs mode ~refresh =
  let config = fetcher#config in

  match gui with
  | Gui.Gui gui ->
      begin match_lwt gui#run_solver fetcher ?test_callback mode reqs ~refresh with
      | `Success sels -> Lwt.return (Some sels)
      | `Aborted_by_user -> Lwt.return None end;
  | Gui.Ui _ ->
      lwt result = Driver.solve_with_downloads fetcher reqs ~force:refresh ~update_local:refresh in
      match result with
      | (false, result, _) -> raise_safe "%s" (Diagnostics.get_failure_reason config result)
      | (true, result, feed_provider) ->
          let sels = result#get_selections in
          match mode with
          | `Select_only -> Lwt.return (Some sels)
          | `Download_only | `Select_for_run ->
              match_lwt Driver.download_selections fetcher ~feed_provider ~include_packages:true sels with
              | `success -> Lwt.return (Some sels)
              | `aborted_by_user -> Lwt.return None

let make_ui config use_gui : Gui.ui_type =
  let use_gui =
    match use_gui, config.dry_run with
    | Yes, true -> raise_safe "Can't use GUI with --dry-run"
    | (Maybe|No), true -> No
    | use_gui, false -> use_gui in

  let make_no_gui () =
    if config.system#isatty Unix.stderr then
      new Console.console_ui
    else
      new Console.batch_ui in

  match use_gui with
  | No -> Gui.Ui (make_no_gui ())
  | Yes | Maybe ->
      (* [try_get_gui] will throw if use_gui is [Yes] and the GUI isn't available *)
      match Gui.try_get_gui config ~use_gui with
      | None -> Gui.Ui (make_no_gui ())
      | Some gui -> Gui.Gui gui
