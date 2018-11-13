(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Support.Common
open OUnit
module Manifest = Zeroinstall.Manifest
module Stores = Zeroinstall.Stores
module Archive = Zeroinstall.Archive
module U = Support.Utils

let assert_str_equal = Fake_system.assert_str_equal
let assert_contains = Fake_system.assert_contains

let write_file (system:system) ~mtime ?(mode=0o644) path contents =
  path |> system#with_open_out [Open_wronly; Open_creat] ~mode (fun ch ->
    output_string ch contents;
  );
  system#set_mtime path mtime

(* Create a set of files, links and directories in target for testing. *)
let populate_sample system target =
  skip_if on_windows "No symlinks, plus permission problems";
  let path = target +/ "MyFile" in
  write_file system path ~mtime:2.0 "Hello";

  let subdir = target +/ "My Dir" in
  system#mkdir subdir 0o755;

  let subfile = subdir +/ "!a file!" in
  write_file system subfile ~mtime:2.0 "Some data.";

  let exe = subfile ^ ".exe" in
  write_file system exe ~mode:0o500 ~mtime:2.0 "Some code.";

  system#symlink ~target:"/the/symlink/target" ~newlink:(target +/ "a symlink")

let check_adds config digest fn =
  let digest = Manifest.parse_digest digest in
  assert_equal None @@ Stores.lookup_maybe config.system [digest] config.stores;
  fn ();
  assert (Stores.lookup_maybe config.system [digest] config.stores <> None)

let suite = "0store">::: [
  "add">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let system = config.system in
    let tmp = U.getenv_ex fake_system "HOME" in
    let sample = tmp +/ "sample" in
    system#mkdir sample 0o755;
    populate_sample system sample;

    let run ?exit ?include_stderr args =
      Test_0install.run_0install ?exit ?include_stderr fake_system ("store" :: args) in

    let digest = ("sha1new", "7e3eb25a072988f164bae24d33af69c1814eb99a") in
    let digest_str = Manifest.format_digest digest in
    assert_equal None @@ Stores.lookup_maybe system [digest] config.stores;

    Fake_system.assert_raises_safe "Incorrect manifest -- archive is corrupted." (lazy (
      ignore @@ run ["add"; digest_str ^ "b"; sample]
    ));

    assert_str_equal "" @@ run ["add"; digest_str; sample];

    let cached = String.trim @@ Test_0install.run_0install fake_system ["store"; "find"; (Manifest.format_digest digest)] in
    assert_str_equal cached @@ Stores.lookup_any system [digest] config.stores;

    assert_contains "MyFile" @@ run ["manifest"; cached];
    assert_contains "MyFile" @@ run ["manifest"; cached; "sha1new"];

    (* Verify... *)
    assert_contains "\nOK" @@ run ["verify"; cached; digest_str];
    assert_contains "\nOK" @@ run ["verify"; cached];
    assert_contains "\nOK" @@ run ["verify"; digest_str];
    Fake_system.assert_raises_safe "Cached item does NOT verify" (lazy (
      ignore @@ run ["verify"; cached; digest_str ^ "a"];
    ));

    (* Full audit *)
    let report = run ~include_stderr:true ["audit"; Filename.dirname cached] in
    assert_contains "Corrupted or modified implementations: 0" report;

    (* Corrupt it... *)
    fake_system#chmod cached 0o700;
    U.touch system (cached +/ "hacked");

    (* Verify again... *)
    Fake_system.assert_raises_safe "Cached item does NOT verify" (lazy (
      ignore @@ run ["verify"; cached];
    ));

    (* Full audit *)
    let report = run ~exit:1 ~include_stderr:true ["audit"; Filename.dirname cached] in
    assert_contains "Cached item does NOT verify" report;
    assert_contains "hacked" report;
    assert_contains "Corrupted or modified implementations: 1" report;
  );

  "add-archive">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if on_windows "Pathnames cause trouble for tar on Windows";
    let digest = "sha1new=290eb133e146635fe37713fd58174324a16d595f" in
    check_adds config digest (fun () ->
      assert_str_equal "" @@ Test_0install.run_0install fake_system ["store"; "add"; digest; Fake_system.test_data "HelloWorld.tgz"];
      assert_str_equal "" @@ Test_0install.run_0install fake_system ["store"; "add"; digest; Fake_system.test_data "HelloWorld.tgz"];
    );
    Fake_system.fake_log#assert_contains "Target directory already exists in cache"
  );

  "add-archive-extract">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if on_windows "Pathnames cause trouble for tar on Windows";
    let digest = "sha1new=491678c37f77fadafbaae66b13d48d237773a68f" in
    check_adds config digest (fun () ->
      assert_str_equal "" @@ Test_0install.run_0install fake_system ["store"; "add"; digest; Fake_system.test_data "HelloWorld.tgz"; "HelloWorld"];
    )
  );

  "manifest">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if on_windows "mtime returns -1";
    let system = config.system in
    let home = U.getenv_ex fake_system "HOME" in
    assert_str_equal "" @@ Manifest.generate_manifest system "sha1new" home;

    let path = home +/ "MyFile" in
    write_file system path ~mode:0o600 ~mtime:2.0 "Hello";
    assert_str_equal "F f7ff9e8b7bb2e09b70935a5d785e0cc5d9d0abf0 2 5 MyFile\n" @@
                     Manifest.generate_manifest system "sha1new" home;

    system#unlink path;
    let path = home +/ "MyLink" in
    system#symlink ~target:"Hello" ~newlink:path;
    assert_str_equal "S f7ff9e8b7bb2e09b70935a5d785e0cc5d9d0abf0 5 MyLink\n" @@
                     Manifest.generate_manifest system "sha1new" home;
  );

  "list">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = Test_0install.run_0install fake_system ["store"; "list"] in
    assert_contains "User store" out;
    assert_contains "No system stores." out;
  );

  "copy">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let system = config.system in
    let home = U.getenv_ex fake_system "HOME" in
    let source = home +/ "badname" in
    system#mkdir source 0o755;

    populate_sample system source;

    assert_str_equal "F f7ff9e8b7bb2e09b70935a5d785e0cc5d9d0abf0 2 5 MyFile\n\
                      S 570b0ce957ab43e774c82fca0ea3873fc452278b 19 a symlink\n\
                      D /My Dir\n\
                      F 0236ef92e1e37c57f0eb161e7e2f8b6a8face705 2 10 !a file!\n\
                      X b4ab02f2c791596a980fd35f51f5d92ee0b4705c 2 10 !a file!.exe\n" @@
                     Manifest.generate_manifest system "sha1new" source;

    let alg = "sha1" in
    let digest = Manifest.add_manifest_file system alg source in

    let copy = home +/ "copy" in
    system#mkdir copy 0o700;

    let run ?exit ?include_stderr args =
      Test_0install.run_0install ?exit ?include_stderr fake_system ("store" :: args) in

    (* Source must be in the form alg=value *)
    Fake_system.assert_raises_safe "Unknown digest type 'badname'" (lazy (
      ignore @@ run ["copy"; source; copy];
    ));

    let source, badname = home +/ (Manifest.format_digest (alg, digest)), source in
    system#chmod badname 0o755;		(* can't rename RO directories on MacOS X *)
    system#rename badname source;
    system#chmod source 0o555;

    (* Can't copy sha1 implementations (unsafe) *)
    Fake_system.assert_raises_safe "Sorry, the 'sha1' algorithm does not support copying." (lazy (
      ignore @@ run ["copy"; source; copy];
    ));

    (* Already have a .manifest *)
    Fake_system.assert_raises_safe "Directory '.*' already contains a .manifest file" (lazy (
      ignore @@ Manifest.add_manifest_file system alg source
    ));

    system#chmod source 0o700;
    system#unlink (source +/ ".manifest");

    (* Switch to sha1new *)
    let alg = "sha1new" in
    let digest = (alg, Manifest.add_manifest_file system alg source) in
    let digest_str = Manifest.format_digest digest in
    let source, old = (home +/ digest_str), source in
    system#chmod old 0o755;
    system#rename old source;
    system#chmod source 0o555;

    assert_str_equal "" @@ run ["copy"; source; copy];

    assert_str_equal "Hello" @@ U.read_file system (copy +/ digest_str +/ "MyFile");

    Manifest.verify system ~digest (copy +/ digest_str);
  );

  "optimise">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let system = config.system in
    let tmp = U.getenv_ex fake_system "HOME" in
    let sample = tmp +/ "sample" in
    system#mkdir sample 0o755;
    populate_sample system sample;

    Lwt_main.run @@ Stores.add_dir_to_cache config ("sha1new", "7e3eb25a072988f164bae24d33af69c1814eb99a") sample;

    let subfile = sample +/ "My Dir" +/ "!a file!.exe" in
    fake_system#chmod subfile 0o755;
    subfile |> system#with_open_out [Open_wronly;Open_trunc] ~mode:0 (fun ch ->
      output_string ch "Extra!\n"
    );
    system#set_mtime subfile 2.0;

    Lwt_main.run @@ Stores.add_dir_to_cache config ("sha1new", "40861a33dba4e7c26d37505bd9693511808c0c35") sample;

    let impl_a = Stores.lookup_any system [("sha1new", "7e3eb25a072988f164bae24d33af69c1814eb99a")] config.stores in
    let impl_b = Stores.lookup_any system [("sha1new", "40861a33dba4e7c26d37505bd9693511808c0c35")] config.stores in

    let same_inode name =
      match system#lstat (impl_a +/ name), system#lstat (impl_b +/ name) with
      | Some a, Some b -> a.Unix.st_ino = b.Unix.st_ino
      | _ -> assert false in

    assert (not (same_inode "My Dir/!a file!"));
    assert (not (same_inode "My Dir/!a file!.exe"));

    let out = Test_0install.run_0install ~include_stderr:true fake_system ["store"; "optimise"; List.hd config.stores] in
    assert_contains "Space freed up : 15 bytes"out;

    let out = Test_0install.run_0install ~include_stderr:true fake_system ["store"; "optimise"; List.hd config.stores] in
    assert_contains "No duplicates found; no changes made." out;

    assert (same_inode "My Dir/!a file!");
    assert (not (same_inode "My Dir/!a file!.exe"));
  );
]
