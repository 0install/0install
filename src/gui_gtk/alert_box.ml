(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A simple error report box *)

open Gtk_common

let report_info ?parent ~title message =
  let box = GWindow.message_dialog
    ?parent
    ~message_type:`INFO
    ~title
    ~message
    ~buttons:GWindow.Buttons.ok
    () in
  box#connect#response ==> (fun _ -> box#destroy ());
  box#show ()

let last_error = ref None

let report_error ?parent ex =
  last_error := Some ex;
  Support.Logging.dump_crash_log ~ex ();
  let error_box = GWindow.message_dialog
    ?parent
    ~message_type:`ERROR
    ~title:"Error"
    ~message:(Printexc.to_string ex)
    ~buttons:GWindow.Buttons.ok
    () in
  error_box#connect#response ==> (fun _ -> error_box#destroy ());
  error_box#show ()
