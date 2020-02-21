(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit

let assert_str_equal = Fake_system.assert_str_equal
let assert_contains = Fake_system.assert_contains

let arglist = Fake_system.test_data "runnable" +/ "ArgList.xml"
let runnable = Fake_system.test_data "runnable" +/ "Runnable.xml"
let runexec = Fake_system.test_data "runnable" +/ "RunExec.xml"
let recursive_runner = Fake_system.test_data "runnable" +/ "RecursiveRunner.xml"
let command_feed = Fake_system.test_data "Command.xml"
let package_selections = Fake_system.test_data "package-selection.xml"


let run_0install (fake_system:Fake_system.fake_system) args =
  fake_system#set_spawn_handler (Some Fake_system.real_system#create_process);
  Fake_system.fake_log#reset;
  fake_system#set_argv @@ Array.of_list (Fake_system.test_0install :: args);
  Fake_system.capture_stdout ~include_stderr:false (fun () ->
    try
      let stdout = Format.std_formatter in
      Main.main ~stdout (fake_system : Fake_system.fake_system :> system);
      assert false
    with Fake_system.Did_exec -> ()
  )

let suite = "run">::: [
  "runnable">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    skip_if on_windows "No /bin/sh";
    let out = run_0install fake_system ["run"; "--"; runnable; "user-arg"] in
    assert_str_equal "Runner: script=A test script: args=command-arg -- user-arg\n" out;
  );

  "command-bindings">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    skip_if on_windows "No /bin/sh";
    let out = run_0install fake_system ["run"; "--main=runnable/go.sh"; "-wenv #"; command_feed] in
    assert_contains "LOCAL=" out;
    assert_contains "SELF_COMMAND=" out
  );

  "abs-main">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = Test_0install.run_0install fake_system ["run"; "--dry-run"; "--main=runnable/runner"; command_feed] in
    assert_contains "[dry-run] would execute:" out;
    if on_windows then assert_contains ".\\runnable/runner" out
    else assert_contains "./runnable/runner" out;

    Fake_system.assert_raises_safe ".*not-there" (lazy (
      Test_0install.run_0install fake_system ["run"; "--main=runnable/not-there"; command_feed] |> ignore;
    ));
  );

  "bad-main">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    Fake_system.assert_raises_safe "Can't run: no command specified!" (lazy (
      Test_0install.run_0install fake_system ~exit:1 ["run"; "--dry-run"; "--command="; command_feed] |> ignore
    ));

    Fake_system.assert_raises_safe "Can't use a relative replacement main (relpath) when there is no original one!" (lazy (
      Test_0install.run_0install fake_system ["run"; "--dry-run"; "--command="; "--main=relpath"; command_feed] |> ignore
    ));
  );

  "args">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = Test_0install.run_0install fake_system ["run"; "--dry-run"; runnable] in
    assert_contains "runner-arg" out
  );

  "arg-list">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = Test_0install.run_0install fake_system ["run"; "--dry-run"; arglist] in
    assert_contains "arg-for-runner -X ra1 -X ra2" out;
    assert_contains "command-arg ca1 ca2" out
  );

  "wrapper">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = Test_0install.run_0install fake_system ["run"; "-wecho"; "--dry-run"; runnable] in
    assert_contains "/bin/sh -c echo \"$@\"" out;
    assert_contains "runner-arg" out;
    assert_contains "script" out
  );

  "recursive">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    skip_if on_windows "No /bin/sh";
    let out = run_0install fake_system ["run"; "--"; recursive_runner; "user-arg"] in
    assert_contains "Runner: script=A test script: args=command-arg -- arg-for-runnable recursive-arg -- user-arg" out
  );

  "executable">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    skip_if on_windows "No /bin/sh";
    let out = run_0install fake_system ["run"; "--"; runexec; "user-arg-run"] in
    assert_contains "Runner: script=A test script: args=foo-arg -- var user-arg-run" out;
    assert_contains "Runner: script=A test script: args=command-arg -- path user-arg-run" out
  );

  "run-package">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    skip_if on_windows "No /bin/sh";
    let out = run_0install fake_system ["run"; "--wrapper"; "echo $TEST #"; "--"; package_selections] in
    assert_str_equal "OK" (String.trim out)
  );
]
