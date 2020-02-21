(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
open Zeroinstall.General

module U = Support.Utils
module A = Zeroinstall.Archive
module Manifest = Zeroinstall.Manifest
module Stores = Zeroinstall.Stores

let assert_manifest system required tmpdir =
  let alg = fst @@ Manifest.parse_digest required in
  let manifest_contents = Manifest.generate_manifest system alg tmpdir in
  let actual = Manifest.hash_manifest alg manifest_contents in
  begin try Fake_system.assert_str_equal required (Manifest.format_digest (alg, actual));
  with ex -> print_endline @@ "\n" ^ manifest_contents; raise ex end;

  Zeroinstall.Stores.fixup_permissions system tmpdir;

  let rec check_perms dir =
    match system#readdir dir with
    | Error ex -> raise ex
    | Ok items ->
        items |> Array.iter (fun f ->
          let full = dir +/ f in
          let info = system#lstat full |? lazy (failwith "lstat") in

          match info.Unix.st_kind with
          | Unix.S_LNK -> ()
          | Unix.S_REG ->
              assert (0o444 = info.Unix.st_perm land 0o666)	    (* Must be r-?r-?r-? *)
          | Unix.S_DIR ->
              assert (0o555 = info.Unix.st_perm land 0o777);	    (* Must be r-xr-xr-x *)
              check_perms full
          | _ -> assert false
        ) in
  check_perms tmpdir

let test_archive config expected ?extract archive =
  skip_if on_windows "Pathnames cause trouble on Windows";
  let mime_type = A.type_from_url archive in
  let home = config.system#getenv "HOME" |> Fake_system.expect in
  let destdir = home +/ "dest" in
  config.system#mkdir destdir 0o700;
  A.unpack_over config ~archive:(Fake_system.test_data archive) ~tmpdir:home ~destdir:destdir ?extract ~mime_type |> Lwt_main.run;
  assert_manifest config.system expected destdir

let suite = "archive">::: [
  "extract-over">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    test_archive config "sha1=491678c37f77fadafbaae66b13d48d237773a68f" ~extract:"HelloWorld" "HelloWorld.tgz"
  );

  "special">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if on_windows "Pathnames cause trouble on Windows";
    (* When creating a temporary directory for extracting an archive, always clear
       any special bits. Otherwise, if the parent is set-guid then the tmp directory
       will be too, and the post-extraction check will fail because the permissions
       are wrong (reported by Markus Kiefer). *)
    let system = config.system in
    let home = U.getenv_ex system "HOME" in
    system#chmod home 0o2755;

    let tmpdir = Zeroinstall.Stores.make_tmp_dir config.system config.stores in
    let destdir = U.make_tmp_dir config.system ~prefix:"0store-add-" tmpdir in
    Lwt_main.run @@ A.unpack_over config ~archive:(Fake_system.test_data "HelloWorld.tgz")
      ~tmpdir ~destdir ~mime_type:"application/x-compressed-tar";
    let digest = ("sha1", "3ce644dc725f1d21cfcf02562c76f375944b266a") in
    Lwt_main.run @@ Stores.check_manifest_and_rename config digest destdir
  );

  "bad">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if on_windows "Pathnames cause trouble on Windows";
    let system = config.system in
    let tmpdir = Zeroinstall.Stores.make_tmp_dir system config.stores in
    let destdir = U.make_tmp_dir system ~prefix:"0store-add-" tmpdir in
    Lwt_main.run @@ A.unpack_over config ~archive:(Fake_system.test_data "HelloWorld.tgz")
      ~tmpdir ~destdir ~mime_type:"application/x-compressed-tar";
    let digest = ("sha1", "3ce644dc725f1d21cfcf02562c76f375944b266b") in
    Fake_system.assert_raises_safe "Incorrect manifest -- archive is corrupted" (lazy (
      Lwt_main.run @@ Stores.check_manifest_and_rename config digest destdir
    ))
  );

  "tgz">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    test_archive config "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" "HelloWorld.tgz"
  );

(*   @skipIf(sys.getfilesystemencoding().lower() != "utf-8", "tar only unpacks to utf-8") *)
  "non-ascii-tgz">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    fake_system#putenv "LANG" @@ (Fake_system.real_system#getenv "LANG" |? lazy "en_GB.UTF-8");
    test_archive config "sha1new=e42ffed02179169ef2fa14a46b0d9aea96a60c10" "unicode.tar.gz"
  );

  "dmg">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if (U.find_in_path config.system "hdiutil" = None) "Not running on MacOS X; no hdiutil";
    test_archive config "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" "HelloWorld.dmg"
  );

  "zip">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    test_archive config "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" "HelloWorld.zip"
  );

  "extract">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    test_archive config "sha1=491678c37f77fadafbaae66b13d48d237773a68f" ~extract:"HelloWorld" "HelloWorld.tgz"
  );

(*   @skipIf(sys.getfilesystemencoding().lower() != "utf-8", "tar only unpacks to utf-8") *)
  "extract-non-ascii">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    fake_system#putenv "LANG" @@ (Fake_system.real_system#getenv "LANG" |? lazy "en_GB.UTF-8");
    test_archive config "sha1=add40d8fe047bb1636791e3ae9dc9949cc657845" ~extract:"unicode" "unicode.tar.gz"
  );

  "extract-zip">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    test_archive config "sha1=491678c37f77fadafbaae66b13d48d237773a68f" ~extract:"HelloWorld" "HelloWorld.zip"
  );

  "targz">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    test_archive config "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" "HelloWorld.tgz"
  );

  "tbz">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    test_archive config "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" "HelloWorld.tar.bz2"
  );

  "tar">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    test_archive config "sha1new=290eb133e146635fe37713fd58174324a16d595f" "HelloWorld.tar"
  );

  "rpm">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if (U.find_in_path config.system "rpm2cpio" = None) "Not running; no rpm2cpio";
    skip_if (U.find_in_path config.system "cpio" = None) "Not running; no cpio";
    test_archive config "sha1=7be9228c8fe2a1434d4d448c4cf130e3c8a4f53d" "dummy-1-1.noarch.rpm"
  );

  "deb">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    test_archive config "sha1new=2c725156ec3832b7980a3de2270b3d8d85d4e3ea" "dummy_1-1_all.deb"
  );

  "gem">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    test_archive config "sha1new=fbd4827be7a18f9821790bdfd83132ee60d54647" "hello-0.1.gem"
  );

  "lzma">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if (U.find_in_path config.system "unlzma" = None) "Not running; no unlzma";
    fake_system#putenv "http_proxy" "localhost:8000";
    test_archive config "sha1new=290eb133e146635fe37713fd58174324a16d595f" "HelloWorld.tar.lzma"
  );

  "bad-ext">:: (fun () ->
    Fake_system.assert_raises_safe "Can't guess MIME type from name" (lazy (
      ignore @@ A.type_from_url "ftp://foo/file.foo"
    ))
  );

  "extract-illegal">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    Fake_system.assert_raises_safe "Illegal character in extract attribute" (lazy (
      test_archive config "sha1new=123" "HelloWorld.tgz" ~extract:"Hello`World"
    ))
  );

  "extract-fails">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    Fake_system.assert_raises_safe "Command failed: tar: HelloWorld2: Not found in archive" (lazy (
      test_archive config "sha1new=123" "HelloWorld.tgz" ~extract:"HelloWorld2"
    ))
  );
]
