(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Support.Common
open OUnit
module Stores = Zeroinstall.Stores
module Archive = Zeroinstall.Archive
module Manifest = Zeroinstall.Manifest
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
      "Can't guess MIME type from name (http://example.com/archive.tar.bz2/readme)"
      (lazy (ignore @@ Archive.type_from_url "http://example.com/archive.tar.bz2/readme"));
  );

  "check-type">:: (fun () ->
    let system = (new Fake_system.fake_system None :> system) in
    Fake_system.assert_raises_safe
      "This package looks like a zip-compressed archive, but you don't have the \"unzip\" command I need to extract it. \
       Install the package containing it first." (lazy (Archive.check_type_ok system "application/zip"))
  );

  "check-system-store">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if (Sys.os_type = "Unix" && Unix.geteuid () = 0) "Doesn't work when unit-tests are run as root";
    skip_if on_windows "Uses symlinks";

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
      | Error ex -> raise ex
      | Ok items -> Fake_system.equal_str_lists [] @@ Array.to_list items in

    let check ~system =
      if system then
        check2 system_store (List.hd config.stores)
      else
        check2 (List.hd config.stores) system_store in

    let required_digest = ("sha1new", "ba8222c744bf6ac2807db1beb07ff0ba5c519627") in

    (* Rename into system store *)
    let tmpdir = create_tmp () in
    Stores.check_manifest_and_rename config required_digest tmpdir |> Lwt_main.run;
    check ~system:true;

    (* Copy into system store *)
    fake_system#set_device_boundary (Some system_store);
    let tmpdir = create_tmp () in
    Stores.check_manifest_and_rename config required_digest tmpdir |> Lwt_main.run;
    Fake_system.fake_log#assert_contains "Target is on a different filesystem";
    check ~system:true;

    (* Non-writeable system store *)
    fake_system#chmod system_store 0o555;
    let tmpdir = create_tmp () in
    Stores.check_manifest_and_rename config required_digest tmpdir |> Lwt_main.run;
    check ~system:false;
    Fake_system.fake_log#assert_contains "Target is on a different filesystem";

    (* Non-writeable system store on same device *)
    fake_system#set_device_boundary None;
    let tmpdir = create_tmp () in
    Stores.check_manifest_and_rename config required_digest tmpdir |> Lwt_main.run;
    check ~system:false;

    (* With helper *)
    fake_system#unsetenv "ZEROINSTALL_PORTABLE_BASE";
    let bindir = home +/ "bin" in
    fake_system#mkdir bindir 0o700;
    let helper = bindir +/ "0store-secure-add-helper" in
    helper |> fake_system#atomic_write [Open_wronly; Open_binary] ~mode:0o755 (fun ch ->
      output_string ch "#!/bin/sh\nexit 0\n"
    );
    fake_system#putenv "PATH" (bindir ^ ":" ^ U.getenv_ex config.system "PATH");
    let tmpdir = create_tmp () in
    Stores.check_manifest_and_rename config required_digest tmpdir |> Lwt_main.run;
    Fake_system.fake_log#assert_contains "Added succcessfully using helper"
  );

  "test-helper">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if on_windows "umask not available";
    let home = U.getenv_ex fake_system "HOME" in
    let test = home +/ "test" in
    fake_system#mkdir test 0o755;

    let add digest =
      U.finally_do
        (fun old -> fake_system#chdir old)
        fake_system#getcwd
        (fun _ ->
          fake_system#chdir test;
          Secureadd.handle config [digest]) in

    Fake_system.assert_raises_safe "File '.manifest' doesn't exist" (lazy (add "sha1=123"));

    ignore @@ Zeroinstall.Manifest.add_manifest_file config.system "sha1new" test;

    Fake_system.assert_raises_safe "Sorry, the 'sha1' algorithm does not support copying." (lazy (add "sha1=123"));
    Fake_system.assert_raises_safe "Manifest has been tampered with!" (lazy (add "sha1new=123"));

    let system_cache = home +/ "implementations" in
    fake_system#mkdir system_cache 0o755;
    fake_system#redirect_writes "/var/cache/0install.net/implementations" system_cache;
    let digest = ("sha1new", "da39a3ee5e6b4b0d3255bfef95601890afd80709") in
    add (Manifest.format_digest digest);

    Manifest.verify config.system ~digest (system_cache +/ Manifest.format_digest digest);
  );

  "check-permissions">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if on_windows "Windows doesn't support special bits";
    let tmpdir = Stores.make_tmp_dir config.system config.stores in
    let subdir = tmpdir +/ "subdir" in
    fake_system#mkdir subdir 0o755;
    fake_system#chmod subdir 0o1755;  (* OS X ignores sticky bit in mkdir *)
    Fake_system.assert_raises_safe "Unsafe mode: extracted file .* had special bits set in mode '1755'" (lazy (
      Stores.check_manifest_and_rename config ("sha1", "123") tmpdir |> Lwt_main.run
    ))
  );

  "hash">:: (fun () ->
    let ctx = Support.Hash.create "sha1" in
    Support.Hash.update ctx "foo";
    Support.Hash.update ctx "bar";
    Fake_system.assert_str_equal "8843d7f92416211de9ebb963ff4ce28125932878" (Support.Hash.hex_digest ctx);

    let ctx = Support.Hash.create "sha1" in
    Support.Hash.update ctx "hello";
    Fake_system.assert_str_equal
      "VL2MMHO4YXUKFWV63YHTWSBM3GXKSQ2N"
      (Support.Hash.b32_digest ctx)
  );

  "verify">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let home = U.getenv_ex fake_system "HOME" in
    let tmp = home +/ "source" in
    let path = tmp +/ "MyLink" in
    fake_system#mkdir tmp 0o700;
    fake_system#symlink ~target:"Hello" ~newlink:path;
    let mfile = tmp +/ ".manifest" in

    let test alg =
      let added_digest = (alg, Manifest.add_manifest_file config.system alg tmp) in
      Manifest.verify config.system tmp ~digest:added_digest;
      fake_system#chmod tmp 0o700;
      fake_system#chmod mfile 0o600;  (* For Windows *)
      fake_system#unlink mfile in

    List.iter test ["sha1"; "sha256"; "sha1new"; "sha256new"]
  );
]
