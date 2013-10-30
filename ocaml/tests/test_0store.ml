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
  system#with_open_out [Open_wronly; Open_creat] mode path (fun ch ->
    output_string ch contents;
  );
  system#set_mtime path mtime

(* Create a set of files, links and directories in target for testing. *)
let populate_sample system target =
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

    let cached = trim @@ Test_0install.run_0install fake_system ["store"; "find"; (Manifest.format_digest digest)] in
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
    let digest = "sha1new=290eb133e146635fe37713fd58174324a16d595f" in
    check_adds config digest (fun () ->
      assert_str_equal "" @@ Test_0install.run_0install fake_system ["store"; "add"; digest; Test_0install.feed_dir +/ "HelloWorld.tgz"];
      assert_str_equal "" @@ Test_0install.run_0install fake_system ["store"; "add"; digest; Test_0install.feed_dir +/ "HelloWorld.tgz"];
    );
    Fake_system.fake_log#assert_contains "Target directory already exists in cache"
  );

  "add-archive-extract">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let digest = "sha1new=491678c37f77fadafbaae66b13d48d237773a68f" in
    check_adds config digest (fun () ->
      assert_str_equal "" @@ Test_0install.run_0install fake_system ["store"; "add"; digest; Test_0install.feed_dir +/ "HelloWorld.tgz"; "HelloWorld"];
    )
  );

  "manifest">:: Fake_system.with_fake_config (fun (config, fake_system) ->
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
]
