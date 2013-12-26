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

let make_ui config use_gui : Ui.ui_handler =
  let use_gui =
    match use_gui, config.dry_run with
    | Yes, true -> raise_safe "Can't use GUI with --dry-run"
    | (Maybe|No), true -> No
    | use_gui, false -> use_gui in

  let make_no_gui () =
    if config.system#isatty Unix.stderr then
      (new Console.console_ui :> Ui.ui_handler)
    else
      (new Console.batch_ui :> Ui.ui_handler) in

  match use_gui with
  | No -> make_no_gui ()
  | Yes | Maybe ->
      (* [try_get_gui] will throw if use_gui is [Yes] and the GUI isn't available *)
      Gui.try_get_gui config ~use_gui |? lazy (make_no_gui ())
