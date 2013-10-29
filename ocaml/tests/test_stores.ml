(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Support.Common
open OUnit
module Stores = Zeroinstall.Stores
module Archive = Zeroinstall.Archive
module U = Support.Utils

let suite = "stores">::: [
  "alg-ranking">:: (fun () ->
    assert_equal ("sha256new", "678") @@ Stores.best_digest [
      ("sha1", "123");
      ("sha256new", "678");
      ("sha256", "345");
    ];

    Fake_system.assert_raises_safe "None of the candidate digest algorithms (odd) is supported" (lazy (
      Stores.best_digest [("odd", "123")] |> ignore
    ));
  );

  "get-type">:: (fun () ->
    Fake_system.assert_str_equal "application/x-bzip-compressed-tar" @@ Archive.type_from_url "http://example.com/archive.tar.bz2";
    Fake_system.assert_str_equal "application/zip" @@ Archive.type_from_url "http://example.com/archive.foo.zip";
    Fake_system.assert_raises_safe
      "No 'type' attribute on archive, and I can't guess from the name (http://example.com/archive.tar.bz2/readme)"
      (lazy (ignore @@ Archive.type_from_url "http://example.com/archive.tar.bz2/readme"));
  );

  "check-type">:: (fun () ->
    let system = (new Fake_system.fake_system None :> system) in
    Fake_system.assert_raises_safe
      "This package looks like a zip-compressed archive, but you don't have the \"unzip\" command I need to extract it. \
       Install the package containing it first." (lazy (Archive.check_type_ok system "application/zip"))
  );

  "check-system-store">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let home = U.getenv_ex fake_system "HOME" in
    let system_store = home +/ "system_store" in
    config.stores <- [List.hd config.stores; system_store];

    let create_tmp () =
      Fake_system.fake_log#reset;
      let tmpdir = Stores.make_tmp_dir config.system config.stores in
      let subdir = tmpdir +/ "subdir" in
      fake_system#mkdir subdir 0o755;
      U.touch config.system (tmpdir +/ "empty");
      fake_system#symlink ~newlink:(subdir +/ "mylink") ~target:"target";
      fake_system#set_mtime subdir 345.0;
      tmpdir in

    let check2 expected_store other_store =
      let expected_path = expected_store +/ "sha1new=ba8222c744bf6ac2807db1beb07ff0ba5c519627" in
      assert (fake_system#file_exists (expected_path +/ "empty"));
      Fake_system.assert_str_equal "target" (Fake_system.expect @@ fake_system#readlink (expected_path +/ "subdir" +/ "mylink"));
      U.rmtree config.system ~even_if_locked:true expected_path;
      match fake_system#readdir other_store with
      | Problem ex -> raise ex
      | Success items -> Fake_system.equal_str_lists [] @@ Array.to_list items in

    let check ~system =
      if system then
        check2 system_store (List.hd config.stores)
      else
        check2 (List.hd config.stores) system_store in

    let required_digest = ("sha1new", "ba8222c744bf6ac2807db1beb07ff0ba5c519627") in
    let slave = new Zeroinstall.Python.slave config in

    (* Rename into system store *)
    let tmpdir = create_tmp () in
    Stores.check_manifest_and_rename config slave required_digest tmpdir |> Lwt_main.run;
    check ~system:true;

    (* Copy into system store *)
    fake_system#set_device_boundary (Some system_store);
    let tmpdir = create_tmp () in
    Stores.check_manifest_and_rename config slave required_digest tmpdir |> Lwt_main.run;
    Fake_system.fake_log#assert_contains "Target is on a different filesystem";
    check ~system:true;

    (* Non-writeable system store *)
    fake_system#chmod system_store 0o555;
    let tmpdir = create_tmp () in
    Stores.check_manifest_and_rename config slave required_digest tmpdir |> Lwt_main.run;
    check ~system:false;
    Fake_system.fake_log#assert_contains "Target is on a different filesystem";

    (* Non-writeable system store on same device *)
    fake_system#set_device_boundary None;
    let tmpdir = create_tmp () in
    Stores.check_manifest_and_rename config slave required_digest tmpdir |> Lwt_main.run;
    check ~system:false;

    (* With helper *)
    fake_system#unsetenv "ZEROINSTALL_PORTABLE_BASE";
    let bindir = home +/ "bin" in
    fake_system#mkdir bindir 0o700;
    let helper = bindir +/ "0store-secure-add-helper" in
    fake_system#atomic_write [Open_wronly; Open_binary] helper ~mode:0o755 (fun ch ->
      output_string ch "#!/bin/sh\nexit 0\n"
    );
    fake_system#putenv "PATH" (bindir ^ ":" ^ U.getenv_ex config.system "PATH");
    let tmpdir = create_tmp () in
    Stores.check_manifest_and_rename config slave required_digest tmpdir |> Lwt_main.run;
    Fake_system.fake_log#assert_contains "Added succcessfully using helper"
  );

  "check-permissions">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let slave = new Zeroinstall.Python.slave config in
    let tmpdir = Stores.make_tmp_dir config.system config.stores in
    let subdir = tmpdir +/ "subdir" in
    fake_system#mkdir subdir 0o1755;
    Fake_system.assert_raises_safe "Unsafe mode: extracted file .* had special bits set in mode '1755'" (lazy (
      Stores.check_manifest_and_rename config slave ("sha1", "123") tmpdir |> Lwt_main.run
    ))
  );

  "hash">:: (fun () ->
    let ctx = Support.Hash.create "sha1" in
    Support.Hash.update ctx "foo";
    Support.Hash.update ctx "bar";
    Fake_system.assert_str_equal "8843d7f92416211de9ebb963ff4ce28125932878" (Support.Hash.digest ctx)
  );
]
