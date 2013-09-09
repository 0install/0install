(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Manage the GUI sub-process. *)

open General
open Support.Common

module R = Requirements
module Q = Support.Qdom

let string_of_ynm = function
  | Yes -> "yes"
  | No -> "no"
  | Maybe -> "maybe"

(** Run the GUI to choose and download a set of implementations
 * If [use_gui] is No; just returns `Dont_use_GUI. 
 * If Maybe, uses the GUI if possible.
 * If Yes, uses the GUI or throws an exception. *)
let get_selections_gui config (slave:Python.slave) ?test_callback:_ ?(systray=false) mode reqs ~refresh ~use_gui =
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
    | `Select_only -> "for-select"
    | `Download_only | `Select_for_update -> "for-download"
    | `Select_for_run -> "for-run" in

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
