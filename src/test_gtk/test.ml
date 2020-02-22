(* Copyright (C) 2020, Thomas Leonard
   See the README file for details, or visit http://0install.net. *)

open Support
open Support.Common
open OUnit

let () =
  Unix.putenv "http_proxy" "localhost:8000";    (* Prevent accidents *)
  Unix.putenv "https_proxy" "localhost:1112";
  Unix.putenv "DISPLAY" "";
  Unix.putenv "ZEROINSTALL_PORTABLE_BASE" "";
  Unix.putenv "ZEROINSTALL_UNITTESTS" "true";
  Unix.putenv "ZEROINSTALL_CRASH_LOGS" ""

module System = Support.System.RealSystem(Unix)

let system = new System.real_system

let tests_dir = Utils.abspath system "."
let build_dir = Filename.dirname tests_dir

let on_osx =
  match system#platform.Platform.os with
  | "Darwin" | "MacOSX" -> true
  | _ -> false

let assert_contains expected whole =
  try ignore @@ Str.search_forward (Str.regexp_string expected) whole 0
  with Not_found -> assert_failure (Printf.sprintf "Expected string '%s' not found in '%s'" expected whole)

let suite =
  (* Check we can load the GTK plugin *)
  "gui">:: (fun () ->
    skip_if on_osx "GTK test hangs on OS X";
    skip_if on_windows "Doesn't look at $DISPLAY";
    let plugin_path = build_dir +/ "gui_gtk" +/ "gui_gtk.cma" |> Dynlink.adapt_filename in
    skip_if (not (Sys.file_exists plugin_path)) "GTK plugin not found";
    Unix.putenv "DISPLAY" "dummy";
    Unix.putenv "ZEROINSTALL_PORTABLE_BASE" "/idontexist";
    (* We copied the binary to 'tests/0install', but need to pretend that it's in its final
       location so that it can find the GTK plugin. *)
    let argv = [| build_dir +/ "0install"; "config"; "-v" |] in
    let exe = tests_dir +/ "0install" in
    let out = Lwt_process.pread ~stderr:(`FD_copy Unix.stdout) (exe, argv) |> Lwt_main.run in
    assert_contains "Initialising GTK GUI" out;
    assert_contains "Failed to create GTK GUI" out;
    assert_contains "auto_approve_keys = True" out;
    Unix.putenv "DISPLAY" "";
    Unix.putenv "ZEROINSTALL_PORTABLE_BASE" "";
  )

let is_error = function
  | RFailure _ | RError _ -> true
  | _ -> false

let () =
  Printexc.record_backtrace true;
  let results = run_test_tt_main suite in
  Format.print_newline ();
  if List.exists is_error results then exit 1
