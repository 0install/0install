(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A simple error report box *)

open Support.Common

let () = ignore on_windows

let report_error ?parent ex =
  let error_box = GWindow.message_dialog
    ?parent
    ~message_type:`ERROR
    ~title:"Error"
    ~message:(Printexc.to_string ex)
    ~buttons:GWindow.Buttons.ok
    () in
  error_box#connect#response ~callback:(fun _ -> error_box#destroy ()) |> ignore;
  error_box#show ()
