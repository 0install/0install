(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A GTK GUI plugin *)

open Support.Common

let string_of_ynm = function
  | Yes -> "yes"
  | No -> "no"
  | Maybe -> "maybe"

let try_get_gtk_gui config use_gui =
  let slave = new Zeroinstall.Python.slave config in
  if slave#invoke "check-gui" [`String (string_of_ynm use_gui)] Yojson.Basic.Util.to_bool |> Lwt_main.run then (
    Some (new Zeroinstall.Ui.gui_ui slave)
  ) else (
    None
  )

let () =
  log_info "Initialising GTK GUI";
  Zeroinstall.Gui.register_plugin try_get_gtk_gui
