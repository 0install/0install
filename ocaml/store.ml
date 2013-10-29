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

let add_dir config ~digest dir =
  let digest = Zeroinstall.Stores.parse_digest digest in
  Lwt_main.run @@ Zeroinstall.Stores.add_dir_to_cache config digest dir

let add_archive options ~digest ?extract archive =
  let digest = Zeroinstall.Stores.parse_digest digest in
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

let handle_add options flags args =
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  match args with
  | [digest; source] ->
      if U.is_dir options.config.system source then (
        add_dir options.config ~digest source
      ) else (
        add_archive options ~digest source
      )
  | [digest; archive; extract] -> add_archive options ~digest ~extract archive
  | _ -> raise (Support.Argparse.Usage_error 1)
