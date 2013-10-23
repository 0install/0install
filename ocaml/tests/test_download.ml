(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* These tests actually run a dummy web-server. *)

open Zeroinstall.General
open Support.Common
open OUnit

let assert_contains = Fake_system.assert_contains

let run_0install fake_system ?(exit=0) args =
  Fake_system.fake_log#reset;
  fake_system#set_argv @@ Array.of_list (Test_0install.test_0install :: args);
  Fake_system.capture_stdout (fun () ->
    try Main.main (fake_system :> system); assert (exit = 0)
    with System_exit n -> assert_equal ~msg:"exit code" n exit
  )

let suite = "download">::: [
  "accept-key">:: Server.with_server (fun (config, fake_system) server ->
    Zeroinstall.Config.save_config {config with
      key_info_server = Some "http://localhost:3333/key-info"
    };

    server#expect [`File "Hello";
      `File "6FCF121BE2390E0B.gpg"; `File "/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B";
      `File "HelloWorld.tgz"];

    Fake_system.assert_raises_safe "Path '.*/HelloWorld/Missing' does not exist" (lazy (
      let out = run_0install fake_system ["run"; "--main=Missing"; "-v"; "http://localhost:8000/Hello"] in
      Fake_system.assert_str_equal "" out
    ));
    Fake_system.fake_log#assert_contains "Automatically approving key for new feed http://localhost:8000/Hello based on response from key info server: Approved for testing";
  );
]
