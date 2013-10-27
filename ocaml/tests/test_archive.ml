(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
open Zeroinstall.General

module U = Support.Utils
module A = Zeroinstall.Archive

let assert_manifest (slave:Zeroinstall.Python.slave) required tmpdir =
  slave#invoke (`List [`String "assert-manifest"; `String required; `String tmpdir]) Zeroinstall.Python.expect_null

let test_archive config expected ?extract archive =
  let mime_type = A.type_from_url archive in
  let home = config.system#getenv "HOME" |> Fake_system.expect in
  let slave = new Zeroinstall.Python.slave config in
  A.unpack_over config.system slave ~archive:(Test_0install.feed_dir +/ archive) ~tmpdir:home ~destdir:home ?extract ~mime_type |> Lwt_main.run;
  assert_manifest slave expected home

let suite = "archive">::: [
  "extract-over">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    test_archive config "sha1=491678c37f77fadafbaae66b13d48d237773a68f" ~extract:"HelloWorld" "HelloWorld.tgz"
  );
]
