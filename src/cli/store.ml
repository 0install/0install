(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install store add" command *)

open Options
open Zeroinstall.General
open Support
open Support.Common

module U = Support.Utils
module A = Zeroinstall.Archive
module Stores = Zeroinstall.Stores
module Manifest = Zeroinstall.Manifest

let add_dir config ~digest dir =
  let digest = Manifest.parse_digest_loose digest in
  Lwt_main.run @@ Zeroinstall.Stores.add_dir_to_cache config digest dir

let add_archive options ~digest ?extract archive =
  let digest = Manifest.parse_digest_loose digest in
  let config = options.config in
  let mime_type = A.type_from_url archive in
  A.check_type_ok config.system mime_type;
  U.finally_do
    (fun tmpdir -> U.rmtree ~even_if_locked:true config.system tmpdir)
    (Zeroinstall.Stores.make_tmp_dir config.system config.stores)
    (fun tmpdir ->
      let destdir = U.make_tmp_dir config.system ~prefix:"0store-add-" tmpdir in
      Lwt_main.run @@ A.unpack_over config ~archive ~tmpdir ~destdir ?extract ~mime_type;
      Lwt_main.run @@ Zeroinstall.Stores.check_manifest_and_rename config digest destdir
    )

let handle_find options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  match args with
  | [digest] ->
      let digest = Manifest.parse_digest_loose digest in
      let config = options.config in
      begin try
        let path = Stores.lookup_any config.system [digest] config.stores in
        Format.fprintf options.stdout "%s@." path
      with Zeroinstall.Stores.Not_stored msg ->
        Safe_exn.failf "%s" msg end
  | _ -> raise (Support.Argparse.Usage_error 1)

let handle_verify options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  let config = options.config in
  let system = config.system in
  let verify dir digest =
    let print fmt = Format.fprintf options.stdout (fmt ^^ "@.") in
    print "Verifying %s" dir;
    Manifest.verify system ~digest dir;
    print "OK" in
  match args with
  | [dir; digest] ->
     let digest = Manifest.parse_digest_loose digest in
      verify dir digest
  | [dir] when U.is_dir system dir ->
     let digest = Manifest.parse_digest (Filename.basename dir) in
      verify dir digest
  | [digest] ->
      let digest = Manifest.parse_digest_loose digest in
      let dir = Stores.lookup_any system [digest] config.stores in
      verify dir digest
  | _ -> raise (Support.Argparse.Usage_error 1)

let handle_audit options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  let config = options.config in
  let system = config.system in
  let dirs =
    match args with
    | [] -> config.stores
    | dirs -> dirs in

  let audit_ls = dirs |> List.filter_map (fun dir ->
    if U.is_dir system dir then Some (
      let items =
        match system#readdir dir with
        | Error ex -> raise ex
        | Ok items -> items in
      Array.sort String.compare items;
      (dir, items)
    ) else if args <> [] then (
      Safe_exn.failf "No such directory '%s'" dir
    ) else
      None
  ) in

  let total = audit_ls |> List.fold_left (fun acc (_, items) -> acc + Array.length items) 0 in

  let print fmt = Format.fprintf options.stdout (fmt ^^ "@.") in

  let verified = ref 0 in
  let failures = ref [] in
  let i = ref 0 in
  audit_ls |> List.iter (fun (root, impls) ->
    print "Scanning %s" root;
    impls |> Array.iter (fun required_digest_str ->
      incr i;
      let path = root +/ required_digest_str in
      let digest =
        try Some (Manifest.parse_digest required_digest_str)
        with Safe_exn.T _ ->
          print "Skipping non-implementation directory %s" path;
          None in

      match digest with
      | None -> ()
      | Some digest ->
          try
            let msg = Printf.sprintf "[%d / %d] Verifying %s" !i total required_digest_str in
            print_string msg;
            flush stdout;
            Manifest.verify system path ~digest;
            let blank = String.make (String.length msg) ' ' in
            Printf.printf "\r%s\r" blank;
            incr verified;
          with Safe_exn.T e ->
            print "";
            failures := path :: !failures;
            print "%a" Safe_exn.pp e
    )
  );
  if !failures <> [] then  (
    print "\nList of corrupted or modified implementations:";
    !failures |> List.iter (print "%s");
    print ""
  );
  print "Checked %d items" !i;
  print "Successfully verified implementations: %d" !verified;
  print "Corrupted or modified implementations: %d" (List.length !failures);
  if !failures <> [] then
    raise (System_exit 1)

let handle_manifest options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  let dir, alg =
    match args with
    | [dir] ->
        let alg =
          try fst (Manifest.parse_digest (Filename.basename dir))
          with Safe_exn.T _ -> "sha1new" in
        (dir, alg)
    | [dir; alg] ->
        (dir, alg)
    | _ -> raise (Support.Argparse.Usage_error 1) in
  let system = options.config.system in
  let manifest_contents = Manifest.generate_manifest system alg dir in
  Format.fprintf options.stdout "%s%!" manifest_contents;
  let digest = (alg, Manifest.hash_manifest alg manifest_contents) |> Manifest.format_digest in
  Format.fprintf options.stdout "%s@." digest

let handle_list options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  if args <> [] then raise (Support.Argparse.Usage_error 1);
  let print fmt = Format.fprintf options.stdout (fmt ^^ "@.") in
  match options.config.stores with
  | [] -> print "No stores configured!"
  | user :: system_stores ->
      print "User store (writable) : %s" user;
      if system_stores = [] then
        print "No system stores."
      else
        system_stores |> List.iter (fun dir ->
          print "System store          : %s" dir
        )

let handle_copy options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  let system = options.config.system in
  let source, target =
    match args with
    | [source] -> (source, List.hd options.config.stores)
    | [source; target] -> (source, target)
    | _ -> raise (Support.Argparse.Usage_error 1) in

  if not (U.is_dir system source) then
    Safe_exn.failf "Source directory '%s' not found" source;

  if not (U.is_dir system target) then
    Safe_exn.failf "Target directory '%s' not found" target;

  let manifest_path = source +/ ".manifest" in
  if not (system#file_exists manifest_path) then
    Safe_exn.failf "Source manifest '%s' not found" manifest_path;

  let required_digest = Filename.basename source |> Manifest.parse_digest in
  let manifest_data = U.read_file system manifest_path in

  Manifest.copy_tree_with_verify system source target manifest_data required_digest

let handle_add options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);

  match args with
  | [digest; source] ->
      if U.is_dir options.config.system source then (
        add_dir options.config ~digest source
      ) else (
        add_archive options ~digest source
      )
  | [digest; archive; extract] -> add_archive options ~digest ~extract archive
  | _ -> raise (Support.Argparse.Usage_error 1)

let handle_digest options flags args =
  let alg = ref "sha1new" in
  let show_manifest = ref false in
  let show_digest = ref false in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
    | `UseHash a -> alg := a
    | `ShowManifest -> show_manifest := true
    | `ShowDigest -> show_digest := true
  );
  if not !show_manifest then show_digest := true;
  let config = options.config in
  let system = config.system in

  let do_manifest dir =
    let manifest_contents = Manifest.generate_manifest system !alg dir in
    if !show_manifest then Format.fprintf options.stdout "%s%!" manifest_contents;
    if !show_digest then (
      let digest = (!alg, Manifest.hash_manifest !alg manifest_contents) |> Manifest.format_digest in
      Format.fprintf options.stdout "%s@." digest
    ) in

  let do_archive ?extract archive =
    let mime_type = A.type_from_url archive in
    A.check_type_ok config.system mime_type;
    U.finally_do
      (fun tmpdir -> U.rmtree ~even_if_locked:true system tmpdir)
      (Zeroinstall.Stores.make_tmp_dir system config.stores)
      (fun tmpdir ->
        let destdir = U.make_tmp_dir system ~prefix:"0install-digest-" tmpdir in
        Lwt_main.run @@ A.unpack_over config ~archive ~tmpdir ~destdir ?extract ~mime_type;
        do_manifest destdir
      ) in

  match args with
  | [dir] when U.is_dir system dir -> do_manifest dir
  | [archive] -> do_archive archive
  | [archive; extract] -> do_archive ~extract archive
  | _ -> raise (Support.Argparse.Usage_error 1)
