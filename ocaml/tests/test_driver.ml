(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit

open Support.Common
open Zeroinstall
open Zeroinstall.General

module U = Support.Utils
module Q = Support.Qdom

class fake_slave config : Python.slave =
  let cache_path_for url =
    let cache = config.basedirs.Support.Basedir.cache in
    let dir = Support.Basedir.save_path config.system (config_site +/ "interfaces") cache in
    dir +/ Escape.escape url in

  let prog_candidates = ref [] in

  let download_and_import = function
    | "http://example.com/prog.xml" as url ->
        U.copy_file config.system ("prog.xml") (cache_path_for url) 0o644;
        `String "success"
    | url -> failwith url in

  let get_distro_candidates = function
    | "http://example.com/prog.xml" ->
        prog_candidates := [`Assoc [
          ("id", `String "package:my-distro:prog:1.0");
          ("version", `String "1.0");
          ("machine", `String "*");
          ("is_installed", `Bool false);
          ("distro", `String "my-distro");
        ]]; `List []
    | url -> failwith url in

  let get_package_impls = function
    | "http://example.com/prog.xml" -> `List [`List []; `List !prog_candidates]
    | url -> failwith url in

  object (_ : #Python.slave)
    method invoke request ?xml:_ parse_fn =
      match request with
      | `List [`String "get-package-impls"; `String url] -> parse_fn @@ get_package_impls url
      | _ -> raise_safe "invoke: %s" (Yojson.Basic.to_string request)
    method invoke_async request ?xml parse_fn =
      ignore xml;
      log_info "invoke_async: %s" (Yojson.Basic.to_string request);
      match request with
      | `List [`String "download-and-import-feed"; `String url] -> Lwt.return @@ parse_fn @@ download_and_import url
      | `List [`String "get-distro-candidates"; `String url] -> Lwt.return @@ parse_fn @@ get_distro_candidates url
      | _ -> raise_safe "Unexpected request %s" (Yojson.Basic.to_string request)

    method close = ()
    method close_async = failwith "close_async"
    method system = config.system
  end

let suite = "driver">::: [
  "simple">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    fake_system#add_file "/lib/ld-linux.so.2" "/";    (* Enable multi-arch *)
    if on_windows then (
      fake_system#add_dir "C:\\Users\\test\\AppData\\Local\\0install.net\\implementations" [];
      fake_system#add_dir "C:\\ProgramData\\0install.net\\implementations" [];
    ) else (
      fake_system#add_dir "/home/testuser/.cache/0install.net/implementations" [];
      fake_system#add_dir "/var/cache/0install.net/implementations" [];
    );
    let reqs = Requirements.({(default_requirements "http://example.com/prog.xml") with command = None}) in
    let slave = new fake_slave config in
    let distro = new Distro.generic_distribution slave in
    let fetcher = new Fetch.fetcher slave in

    let (ready, result) = Driver.solve_with_downloads config fetcher distro reqs ~force:true ~update_local:true in
    if not ready then
      failwith @@ Diagnostics.get_failure_reason config result;

    match result#get_selections.Q.child_nodes with
    | [ sel ] -> Fake_system.assert_str_equal "package:my-distro:prog:1.0" (ZI.get_attribute "id" sel)
    | _ -> assert_failure "Bad selections"
      
  );
]
