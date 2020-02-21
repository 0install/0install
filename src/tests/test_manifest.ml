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

let assert_str_equal = Fake_system.assert_str_equal

let write_file (system:system) ~mtime ?(mode=0o644) path contents =
  path |> system#with_open_out [Open_wronly; Open_creat] ~mode (fun ch ->
    output_string ch contents;
  );
  system#set_mtime path mtime

let suite = "manifest">::: [
  "empty">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let home = U.getenv_ex config.system "HOME" in
    assert_str_equal "" @@ Manifest.generate_manifest config.system "sha1new" home;
  );

  "old-sha">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if on_windows "No symlinks";
    let system = config.system in
    let home = U.getenv_ex config.system "HOME" in
    let mydir = home +/ "MyDir" in
    system#mkdir mydir 0o700;
    write_file system (home +/ "MyDir" +/ "Hello") "Hello World" ~mtime:30.0;
    let myexec = mydir +/ "Run me" in
    write_file system myexec ~mode:0o700 "Bang!" ~mtime:40.0;
    system#symlink ~target:"Hello" ~newlink:(home +/ "MyDir/Sym link");
    system#set_mtime mydir 20.0;
    assert_str_equal
      "D 20 /MyDir\n\
       F 0a4d55a8d778e5022fab701977c5d840bbc486d0 30 11 Hello\n\
       X 4001b8c42ddfb61c453d04930e8ce78fb3a40bc8 40 5 Run me\n\
       S f7ff9e8b7bb2e09b70935a5d785e0cc5d9d0abf0 5 Sym link\n" @@
       Manifest.generate_manifest system "sha1" home
  );

  "new-sha1">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if on_windows "No symlinks";
    let system = config.system in
    let home = U.getenv_ex config.system "HOME" in
    let mydir = home +/ "MyDir" in
    system#mkdir mydir 0o700;
    write_file system (home +/ "MyDir" +/ "Hello") "Hello World" ~mtime:30.0;
    let myexec = mydir +/ "Run me" in
    write_file system myexec ~mode:0o700 "Bang!" ~mtime:40.0;
    system#symlink ~target:"Hello" ~newlink:(home +/ "MyDir/Sym link");
    system#set_mtime mydir 20.0;
    assert_str_equal
      "D /MyDir\n\
       F 0a4d55a8d778e5022fab701977c5d840bbc486d0 30 11 Hello\n\
       X 4001b8c42ddfb61c453d04930e8ce78fb3a40bc8 40 5 Run me\n\
       S f7ff9e8b7bb2e09b70935a5d785e0cc5d9d0abf0 5 Sym link\n" @@
       Manifest.generate_manifest system "sha1new" home
  );

  "ordering-sha1">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if on_windows "mtime returns -1";
    let system = config.system in
    let home = U.getenv_ex config.system "HOME" in
    let mydir = home +/ "Dir" in
    system#mkdir mydir 0o700;
    write_file system (home +/ "Hello") "Hello World" ~mtime:30.0;
    write_file system (home +/ "Dir" +/ "Hello") "Hello World" ~mtime:30.0;
    system#set_mtime mydir 20.0;
    assert_str_equal
      "F 0a4d55a8d778e5022fab701977c5d840bbc486d0 30 11 Hello\n\
       D /Dir\n\
       F 0a4d55a8d778e5022fab701977c5d840bbc486d0 30 11 Hello\n" @@
       Manifest.generate_manifest system "sha1new" home
  );

  "new-sha256">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if on_windows "No symlinks";
    let system = config.system in
    let home = U.getenv_ex config.system "HOME" in
    let mydir = home +/ "MyDir" in
    system#mkdir mydir 0o700;
    write_file system (home +/ "MyDir" +/ "Hello") "Hello World" ~mtime:30.0;
    let myexec = mydir +/ "Run me" in
    write_file system myexec ~mode:0o700 "Bang!" ~mtime:40.0;
    system#symlink ~target:"Hello" ~newlink:(home +/ "MyDir/Sym link");
    system#set_mtime mydir 20.0;
    assert_str_equal
      "D /MyDir\n\
       F a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e 30 11 Hello\n\
       X 640628586b08f8ed3910bd1e75ba02818959e843b54efafb9c2260a1f77e3ddf 40 5 Run me\n\
       S 185f8db32271fe25f561a6fc938b2e264306ec304eda518007d1764826381969 5 Sym link\n" @@
      Manifest.generate_manifest system "sha256" home
  );

  "ordering">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if on_windows "mtime returns -1";
    let system = config.system in
    let home = U.getenv_ex config.system "HOME" in
    let mydir = home +/ "Dir" in
    system#mkdir mydir 0o700;
    write_file system (home +/ "Hello") "Hello World" ~mtime:30.0;
    system#set_mtime mydir 20.0;
    assert_str_equal
      "F a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e 30 11 Hello\n\
       D /Dir\n" @@
      Manifest.generate_manifest system "sha256" home
  );

  (* @skipIf(sys.getfilesystemencoding().lower() != "utf-8", "tar only unpacks to utf-8") *)
  "non-ascii">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if (Sys.os_type = "Win32") "Paths get messed up on Windows tar";
    let home = U.getenv_ex config.system "HOME" in
    let mydir = home +/ "unicode" in
    let system = config.system in
    system#mkdir mydir 0o700;

    let mime_type = "application/x-compressed-tar" in
    A.unpack_over config ~archive:(Fake_system.test_data "unicode.tar.gz") ~tmpdir:home ~destdir:mydir ~mime_type |> Lwt_main.run;
    assert_str_equal
      "D /unicode\n\
       D /unicode/test-unic\xcc\xa7\xc3\xb8\xc3\xb0e\xcc\x88\n\
       F c1c727274876ed5915c75a907131b8462cfdd5ba278140067dc80a2bcba033d6 1377477018 14 file\n" @@
      Manifest.generate_manifest system "sha256" mydir;

    assert_str_equal
      "D /unicode\n\
       D /unicode/test-unic\xcc\xa7\xc3\xb8\xc3\xb0e\xcc\x88\n\
       F 5f1ff6172591102593950d1ae6c4a78709b1c44c 1377477018 14 file\n" @@
      Manifest.generate_manifest system "sha1new" mydir;
  );

  "parse-manifest">:: (fun () ->
    assert_equal [] @@ Manifest.parse_manifest "";

    let parsed = Manifest.parse_manifest
      "F e3d5983c3dfd415af24772b48276d16122fe5a87 1172429666 2980 README\n\
       X 8a1f3c5f416f0e63140928102c44cd16ec2c6100 1172429666 5816 install.sh\n\
       D /0install\n\
       S 2b37e4457a1a38cfab89391ce1bfbe4dc5473fc3 26 mime-application:x-java-archive.png\n" in

    assert_equal [
      ("README", `File (false, "e3d5983c3dfd415af24772b48276d16122fe5a87", 1172429666., (Int64.of_int 2980)));
      ("install.sh", `File (true, "8a1f3c5f416f0e63140928102c44cd16ec2c6100", 1172429666., (Int64.of_int 5816)));
      ("0install", `Dir [
        ("mime-application:x-java-archive.png", `Symlink ("2b37e4457a1a38cfab89391ce1bfbe4dc5473fc3", (Int64.of_int 26)));
      ]);
    ] parsed;
  );
]
