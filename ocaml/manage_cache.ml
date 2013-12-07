(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install store manage" command *)

open Options
open Zeroinstall.General
open Support.Common

module Manifest = Zeroinstall.Manifest

module F = Zeroinstall.Feed
module FC = Zeroinstall.Feed_cache
module P = Zeroinstall.Python
module U = Support.Utils

let handle options flags args =
  let config = options.config in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  if args <> [] then raise (Support.Argparse.Usage_error 1);

  Zeroinstall.Python.register_handler "verify" (function
    | [`String path] ->
        let digest = Manifest.parse_digest (Filename.basename path) in
        Manifest.verify config.system ~digest path;
        Lwt.return `Null
    | json -> raise_safe "verify: invalid request: %s" (Yojson.Basic.to_string (`List json))
  );

  let gui =
    match Lazy.force options.ui with
    | Zeroinstall.Gui.Gui gui -> gui
    | Zeroinstall.Gui.Ui _ -> raise_safe "GUI not available" in
  gui#open_cache_explorer |> Lwt_main.run
