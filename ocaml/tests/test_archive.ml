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
  Fake_system.assert_str_equal required (Manifest.format_digest (alg, actual));

  Zeroinstall.Stores.fixup_permissions system tmpdir;

  let rec check_perms dir =
    match system#readdir dir with
    | Problem ex -> raise ex
    | Success items ->
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
  let mime_type = A.type_from_url archive in
  let home = config.system#getenv "HOME" |> Fake_system.expect in
  let slave = new Zeroinstall.Python.slave config in
  A.unpack_over config slave ~archive:(Test_0install.feed_dir +/ archive) ~tmpdir:home ~destdir:home ?extract ~mime_type |> Lwt_main.run;
  assert_manifest config.system expected home

let suite = "archive">::: [
  "extract-over">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    test_archive config "sha1=491678c37f77fadafbaae66b13d48d237773a68f" ~extract:"HelloWorld" "HelloWorld.tgz"
  );

  "special">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    (* When creating a temporary directory for extracting an archive, always clear
       any special bits. Otherwise, if the parent is set-guid then the tmp directory
       will be too, and the post-extraction check will fail because the permissions
       are wrong (reported by Markus Kiefer). *)
    let system = config.system in
    let home = U.getenv_ex system "HOME" in
    system#chmod home 0o2755;

    let tmpdir = Zeroinstall.Stores.make_tmp_dir config.system config.stores in
    let destdir = U.make_tmp_dir config.system ~prefix:"0store-add-" tmpdir in
    let slave = new Zeroinstall.Python.slave config in
    Lwt_main.run @@ A.unpack_over config slave ~archive:(Test_0install.feed_dir +/ "HelloWorld.tgz")
      ~tmpdir ~destdir ~mime_type:"application/x-compressed-tar";
    let digest = ("sha1", "3ce644dc725f1d21cfcf02562c76f375944b266a") in
    Lwt_main.run @@ Stores.check_manifest_and_rename config digest destdir
  );

  "bad">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let system = config.system in

    let tmpdir = Zeroinstall.Stores.make_tmp_dir system config.stores in
    let destdir = U.make_tmp_dir system ~prefix:"0store-add-" tmpdir in
    let slave = new Zeroinstall.Python.slave config in
    Lwt_main.run @@ A.unpack_over config slave ~archive:(Test_0install.feed_dir +/ "HelloWorld.tgz")
      ~tmpdir ~destdir ~mime_type:"application/x-compressed-tar";
    let digest = ("sha1", "3ce644dc725f1d21cfcf02562c76f375944b266b") in
    Fake_system.assert_raises_safe "Incorrect manifest -- archive is corrupted" (lazy (
      Lwt_main.run @@ Stores.check_manifest_and_rename config digest destdir
    ))
  );
]
