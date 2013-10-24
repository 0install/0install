(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* These tests actually run a dummy web-server. *)

open Support.Common
open OUnit

module F = Zeroinstall.Feed
module FC = Zeroinstall.Feed_cache

let assert_contains = Fake_system.assert_contains

let run_0install ?stdin fake_system ?(exit=0) args =
  let run = lazy (
    Fake_system.fake_log#reset;
    fake_system#set_argv @@ Array.of_list (Test_0install.test_0install :: args);
    Fake_system.capture_stdout ~include_stderr:true (fun () ->
      try Main.main (fake_system : Fake_system.fake_system :> system); assert (exit = 0)
      with System_exit n -> assert_equal ~msg:"exit code" n exit
    )
  ) in
  match stdin with
  | None -> Lazy.force run
  | Some stdin -> fake_system#with_stdin stdin run

let suite = "download">::: [
  "accept-key">:: Server.with_server (fun (_config, fake_system) server ->
    server#expect [[("Hello", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B", `UnknownKey)];
      [("HelloWorld.tgz", `Serve)]
    ];

    Fake_system.assert_raises_safe "Path '.*/HelloWorld/Missing' does not exist" (lazy (
      run_0install fake_system ~stdin:"Y\n" ["run"; "--main=Missing"; "-v"; "http://localhost:8000/Hello"] |> ignore
    ));
    Fake_system.fake_log#assert_contains "Trusting DE937DD411906ACF7C263B396FCF121BE2390E0B for localhost:8000";
  );

  "import">:: Server.with_server (fun (config, fake_system) server ->
    Fake_system.assert_raises_safe "File 'NO-SUCH-FILE' does not exist" (lazy (
      run_0install fake_system ["import"; "-v"; "NO-SUCH-FILE"] |> ignore
    ));

    assert_equal None @@ FC.get_cached_feed config (`remote_feed "http://localhost:8000/Hello");

    server#expect [
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B", `UnknownKey)];
    ];

    let trust_db = new Zeroinstall.Trust.trust_db config in

    let domain = "localhost:8000" in
    assert (not (trust_db#is_trusted ~domain "DE937DD411906ACF7C263B396FCF121BE2390E0B"));
    let out = run_0install fake_system ~stdin:"Y\n" ["import"; "-v"; Test_0install.feed_dir +/ "Hello"] in
    assert_contains "Warning: Nothing known about this key!" out;
    Fake_system.fake_log#assert_contains "Trusting DE937DD411906ACF7C263B396FCF121BE2390E0B for localhost:8000";
    assert (trust_db#is_trusted ~domain "DE937DD411906ACF7C263B396FCF121BE2390E0B");

    (* Check we imported the interface after trusting the key *)
    let hello = FC.get_cached_feed config (`remote_feed "http://localhost:8000/Hello") |> Fake_system.expect in
    assert_equal 1 @@ StringMap.cardinal hello.F.implementations;

    (* Shouldn't need to prompt the second time *)
    let out = run_0install fake_system ~stdin:"" ["import"; Test_0install.feed_dir +/ "Hello"] in
    Fake_system.assert_str_equal "" out;
  );
]
