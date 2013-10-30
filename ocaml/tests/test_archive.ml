(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
open Zeroinstall.General

module U = Support.Utils
module A = Zeroinstall.Archive
module Manifest = Zeroinstall.Manifest

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
]
