(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit

module U = Support.Utils

let on_osx =
  match Fake_system.real_system#platform.Platform.os with
  | "Darwin" | "MacOSX" -> true
  | _ -> false

let suite =
  (* Check we can load the GTK plugin *)
  "gui">:: (fun () ->
    skip_if on_osx "GTK test hangs on OS X";
    skip_if on_windows "Doesn't look at $DISPLAY";
    let plugin_path = Fake_system.build_dir +/ "gui_gtk.cma" |> Dynlink.adapt_filename in
    skip_if (not (Sys.file_exists plugin_path)) "GTK plugin not found";
    Unix.putenv "DISPLAY" "dummy";
    let argv = U.make_command Fake_system.real_system [Fake_system.build_dir +/ "0install"; "config"; "-v"] in
    let out = Lwt_process.pread ~stderr:(`FD_copy Unix.stdout) argv |> Lwt_main.run in
    Fake_system.assert_contains "Initialising GTK GUI" out;
    Fake_system.assert_contains "Failed to create GTK GUI" out;
    Fake_system.assert_contains "auto_approve_keys = True" out;
    Unix.putenv "DISPLAY" "";
  )
