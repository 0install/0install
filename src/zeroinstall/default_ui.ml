(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** High-level helper functions *)

open General
open Support
open Support.Common

let make_ui config ~use_gui : Ui.ui_handler =
  let use_gui =
    match use_gui, config.dry_run with
    | `Yes, true -> Safe_exn.failf "Can't use GUI with --dry-run"
    | (`Auto | `No), true -> `No
    | use_gui, false -> (use_gui :> [`Yes | `No | `Auto]) in

  let make_no_gui () =
    if config.system#isatty Unix.stderr then
      (new Console.console_ui :> Ui.ui_handler)
    else
      (new Console.batch_ui :> Ui.ui_handler) in

  match use_gui with
  | `No -> make_no_gui ()
  | `Yes | `Auto ->
      (* [try_get_gui] will throw if use_gui is [Yes] and the GUI isn't available *)
      Gui.try_get_gui config ~use_gui |? lazy (make_no_gui ())
