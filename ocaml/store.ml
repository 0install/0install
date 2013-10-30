(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install store add" command *)

open Options
open Zeroinstall.General
open Support.Common

let () = ignore on_windows

module U = Support.Utils
module A = Zeroinstall.Archive
module Stores = Zeroinstall.Stores
module Manifest = Zeroinstall.Manifest

let add_dir config ~digest dir =
  let digest = Manifest.parse_digest digest in
  Lwt_main.run @@ Zeroinstall.Stores.add_dir_to_cache config digest dir

let add_archive options ~digest ?extract archive =
  let digest = Manifest.parse_digest digest in
  let config = options.config in
  let mime_type = A.type_from_url archive in
  A.check_type_ok config.system mime_type;
  U.finally_do
    (fun tmpdir -> U.rmtree ~even_if_locked:true config.system tmpdir)
    (Zeroinstall.Stores.make_tmp_dir config.system config.stores)
    (fun tmpdir ->
      let destdir = U.make_tmp_dir config.system ~prefix:"0store-add-" tmpdir in
      Lwt_main.run @@ A.unpack_over config options.slave ~archive ~tmpdir ~destdir ?extract ~mime_type;
      Lwt_main.run @@ Zeroinstall.Stores.check_manifest_and_rename config digest destdir
    )

let handle_find options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  match args with
  | [digest] ->
      let digest = Manifest.parse_digest digest in
      let config = options.config in
      begin try
        let path = Stores.lookup_any config.system [digest] config.stores in
        config.system#print_string (path ^ "\n")
      with Zeroinstall.Stores.Not_stored msg ->
        raise_safe "%s" msg end
  | _ -> raise (Support.Argparse.Usage_error 1)

let handle_verify options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  let config = options.config in
  let system = config.system in
  let verify dir digest =
    let print fmt = Support.Utils.print config.system fmt in
    print "Verifying %s" dir;
    Manifest.verify system ~digest dir;
    print "OK" in
  match args with
  | [dir; digest] ->
     let digest = Manifest.parse_digest digest in
      verify dir digest
  | [dir] when U.is_dir system dir ->
     let digest = Manifest.parse_digest (Filename.basename dir) in
      verify dir digest
  | [digest] ->
      let digest = Manifest.parse_digest digest in
      let dir = Stores.lookup_any system [digest] config.stores in
      verify dir digest
  | _ -> raise (Support.Argparse.Usage_error 1)

let handle_audit options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  let dirs =
    match args with
    | [] -> options.config.stores
    | dirs -> dirs in
  let dirs = dirs |> List.map (fun d -> `String d) in
  options.slave#invoke (`List [`String "audit"; `List dirs]) (function
    | `Bool true -> ()
    | `Bool false -> raise (System_exit 1)
    | _ -> assert false
  )

let handle_manifest options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  let dir, alg =
    match args with
    | [dir] ->
        let alg =
          try fst (Manifest.parse_digest (Filename.basename dir))
          with Safe_exception _ -> "sha1new" in
        (dir, alg)
    | [dir; alg] ->
        (dir, alg)
    | _ -> raise (Support.Argparse.Usage_error 1) in
  let system = options.config.system in
  let manifest_contents = Manifest.generate_manifest system alg dir in
  system#print_string manifest_contents;
  let digest = (alg, Manifest.hash_manifest alg manifest_contents) |> Manifest.format_digest in
  system#print_string (digest ^ "\n")

let handle_list options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  if args <> [] then raise (Support.Argparse.Usage_error 1);
  let print fmt = Support.Utils.print options.config.system fmt in
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
