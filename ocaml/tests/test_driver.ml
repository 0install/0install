(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit

open Support.Common
open Zeroinstall
open Zeroinstall.General

module U = Support.Utils
module Q = Support.Qdom

let cache_path_for config url = Feed_cache.get_save_cache_path config (`remote_feed url)

class fake_slave config handler : Python.slave =
  object (_ : #Python.slave)
    method invoke request ?xml parse_fn =
      ignore xml;
      match request with
      | `List [`String "get-package-impls"; `String url] -> parse_fn @@ handler#get_package_impls url
      | _ -> raise_safe "invoke: %s" (Yojson.Basic.to_string request)
    method invoke_async request ?xml parse_fn =
      ignore xml;
      log_info "invoke_async: %s" (Yojson.Basic.to_string request);
      match request with
      | `List [`String "download-url"; `String url; `String _hint; timeout] ->
          let start_timeout = StringMap.find "start-timeout" !Zeroinstall.Python.handlers in
          ignore @@ start_timeout [timeout];
          Lwt.return @@ parse_fn @@ handler#download_url url
      | `List [`String "get-distro-candidates"; `String url] -> Lwt.return @@ parse_fn @@ handler#get_distro_candidates url
      | _ -> raise_safe "Unexpected request %s" (Yojson.Basic.to_string request)

    method close = ()
    method close_async = failwith "close_async"
    method system = config.system
  end

let fake_fetcher config handler =
  object
    method download_and_import_feed (`remote_feed url) =
      match handler#get_feed url with
      | `file path ->
          let xml = U.read_file config.system path in
          let root = `String (0, xml) |> Xmlm.make_input |> Q.parse_input None in
          `update (root, None) |> Lwt.return
      | `xml root -> `update (root, None) |> Lwt.return
      | `problem msg -> `problem (msg, None) |> Lwt.return

    method download_impls impls : [ `success | `aborted_by_user ] Lwt.t =
      handler#download_impls impls |> Lwt.return
  end

(** Parse a test-case in driven.xml *)
let make_driver_test test_elem =
  ZI.check_tag "test" test_elem;
  let name = ZI.get_attribute "name" test_elem in
  name >:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let expand_tmp s =
      Str.global_replace (Str.regexp_string "@TMP@") tmpdir s in
    let reqs = ref (Zeroinstall.Requirements.default_requirements "") in
    let fails = ref false in
    let expected_problem = ref "missing-problem" in
    let expected_output = ref "missing-output" in
    let expected_warnings = ref [] in
    let expected_downloads = ref StringSet.empty in
    let expected_digests = ref StringSet.empty in
    let expected_envs = ref [] in
    let args = ref [] in
    let dry_run = ref true in
    let downloadable_feeds = ref StringMap.empty in
    let process child = match ZI.tag child with
    | Some "interface" -> (
        match ZI.get_attribute_opt "uri" child with
        | Some url -> downloadable_feeds := StringMap.add url child !downloadable_feeds
        | None ->
            let local_path = tmpdir +/ (ZI.get_attribute "local-path" child) in
            fake_system#atomic_write [Open_wronly; Open_binary] local_path ~mode:0o644 (fun ch ->
              Support.Qdom.output (Xmlm.make_output @@ `Channel ch) child
            );
    )
    | Some "requirements" ->
        let iface = ZI.get_attribute "interface" child in
        let iface =
          if U.starts_with iface "./" then U.abspath (fake_system :> system) iface
          else iface in
        reqs := {!reqs with
          Requirements.interface_uri = iface;
          Requirements.command = ZI.get_attribute_opt "command" child;
        };
        fails := ZI.get_attribute_opt "fails" child = Some "true";
        dry_run := ZI.get_attribute_opt "dry-run" child = Some "true";
        ZI.iter_with_name child "arg" ~f:(fun arg ->
          args := arg.Support.Qdom.last_text_inside :: !args
        )
    | Some "problem" -> expected_problem := trim child.Support.Qdom.last_text_inside
    | Some "download" -> expected_digests := StringSet.add (ZI.get_attribute "digest" child) !expected_digests
    | Some "set-env" ->
        let name = ZI.get_attribute "name" child in
        let value = ZI.get_attribute "value" child in
        fake_system#putenv name value
    | Some "check-env" ->
        let name = ZI.get_attribute "name" child in
        let value = expand_tmp @@ child.Support.Qdom.last_text_inside in
        expected_envs := (name, value) :: !expected_envs
    | Some "cache" ->
        let user_store = List.hd config.stores in
        let digest_str = ZI.get_attribute "digest" child in
        U.makedirs config.system (user_store +/ digest_str) 0o755;
    | Some "output" -> expected_output := child.Support.Qdom.last_text_inside
    | Some "warning" -> expected_warnings := child.Support.Qdom.last_text_inside :: !expected_warnings
    | _ -> Support.Qdom.raise_elem "Unexpected element" child in
    ZI.iter ~f:process test_elem;

    let handler =
      object
        method get_package_impls _uri = `List [`List []; `List []]

        method download_impls impls =
          ignore @@ Test_0install.handle_download_impls config expected_digests impls;
          `success

        method download_url url = failwith url

        method get_distro_candidates _ = `List []

        method get_feed url =
          try `xml (StringMap.find url !downloadable_feeds)
          with Not_found -> `problem "Unexpected feed requested"
      end in

    let fetcher = fake_fetcher config handler in
    let slave = new fake_slave config handler in
    let driver = Fake_system.make_driver ~slave ~fetcher config in
    let () =
      try
        Fake_system.collect_logging (fun () ->
          let sels = Fake_system.expect @@ Zeroinstall.Helpers.solve_and_download_impls driver !reqs `Select_for_run ~refresh:false ~use_gui:No in
          if !fails then assert_failure "Expected solve_and_download_impls to fail, but it didn't!";
          let actual_env = ref StringMap.empty in
          let output = trim @@ Fake_system.capture_stdout (fun () ->
            let exec cmd ~env =
              ArrayLabels.iter env ~f:(fun binding ->
                let (name, value) = Support.Utils.split_pair Support.Utils.re_equals binding in
                actual_env := StringMap.add name value !actual_env
              );
              print_endline ("Would execute: " ^ Support.Logging.format_argv_for_logging cmd) in
            Zeroinstall.Exec.execute_selections ~exec {config with dry_run = !dry_run} sels (List.rev !args)
          ) in
          let re = Str.regexp !expected_output in
          if not (Str.string_match re output 0) then
            assert_failure (Printf.sprintf "Expected output '%s' but got '%s'" !expected_output output);
          (* Check all expected downloads happened. *)
          StringSet.iter assert_failure !expected_downloads;
          (* Check environment *)
          ListLabels.iter !expected_envs ~f:(fun (name, value) ->
            Fake_system.assert_str_equal value (StringMap.find name !actual_env)
          )
        )
      with Safe_exception (msg, _) ->
        let re = Str.regexp !expected_problem in
        if not (Str.string_match re msg 0) then
          assert_failure (Printf.sprintf "Expected error '%s' but got '%s'" !expected_problem msg) in
    (* Check warnings *)
    let actual_warnings = Fake_system.fake_log#pop_warnings in
    Fake_system.equal_str_lists (List.rev !expected_warnings) actual_warnings;
  )

let suite = "driver">::: [
  "simple">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let reqs = Requirements.({(default_requirements "http://example.com/prog.xml") with command = None}) in
    let handler =
      let prog_candidates = ref [] in
      object
        method download_impls = failwith "download_impls"

        method get_package_impls = function
          | "http://example.com/prog.xml" -> `List [`List []; `List !prog_candidates]
          | url -> failwith url

        method download_url = function
          | url -> failwith url

        method get_distro_candidates = function
          | "http://example.com/prog.xml" ->
              prog_candidates := [`Assoc [
                ("id", `String "package:my-distro:prog:1.0");
                ("version", `String "1.0");
                ("machine", `String "*");
                ("is_installed", `Bool false);
                ("distro", `String "my-distro");
              ]]; `List []
          | url -> failwith url

        method get_feed = function
          | "http://example.com/prog.xml" -> `file "prog.xml"
          | url -> failwith url
      end in
    let slave = new fake_slave config handler in
    let distro = new Distro.generic_distribution slave in
    let fetcher = fake_fetcher config handler in

    let driver = new Driver.driver config fetcher distro slave in
    let (ready, result, _fp) = driver#solve_with_downloads reqs ~force:true ~update_local:true in
    if not ready then
      failwith @@ Diagnostics.get_failure_reason config result;

    match result#get_selections.Q.child_nodes with
    | [ sel ] -> Fake_system.assert_str_equal "package:my-distro:prog:1.0" (ZI.get_attribute "id" sel)
    | _ -> assert_failure "Bad selections"
      
  );

  "noNeedDl">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let handler =
      object
        method download_url = failwith "download_url"
        method download_selections = failwith "download_selections"
        method get_distro_candidates = failwith "get_distro_candidates"
        method get_package_impls = failwith "get_package_impls"
      end in
    let foo_path = Test_0install.feed_dir +/ "Foo.xml" in
    let reqs = Requirements.({(default_requirements foo_path) with command = None}) in
    let slave = new fake_slave config handler in
    let driver = Fake_system.make_driver ~slave config in
    let sels = Zeroinstall.Helpers.solve_and_download_impls driver reqs `Select_for_run ~refresh:false ~use_gui:No in
    assert (sels <> None)
  );

  "source">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let import name =
      U.copy_file config.system (Test_0install.feed_dir +/ name) (cache_path_for config @@ "http://foo/" ^ name) 0o644 in
    import "Binary.xml";
    let distro =
      object
        inherit Distro.distribution config.system
        method is_installed = failwith "is_installed"
        method get_all_package_impls _ = None
        method check_for_candidates = failwith "check_for_candidates"
        val distro_name = "dummy"
      end in
    let reqs = Requirements.default_requirements "http://foo/Binary.xml" in
    let fetcher =
      object
        method download_and_import_feed (`remote_feed url) = raise_safe "download_and_import_feed: %s" url
        method download_impls = failwith "download_impls"
      end in
    let slave = new Zeroinstall.Python.slave config in
    let driver = new Driver.driver config fetcher distro slave in
    let (ready, result, _fp) = driver#solve_with_downloads reqs ~force:false ~update_local:false in
    assert (ready = true);

    let get_ids result =
      ZI.map result#get_selections "selection" ~f:(fun sel -> ZI.get_attribute "id" sel) in

    Fake_system.equal_str_lists ["sha1=123"] @@ get_ids result;

    (* Now ask for source instead *)
    import "Source.xml";
    import "Compiler.xml";
    let reqs = {reqs with Requirements.source = true; command = None} in
    let driver = new Driver.driver {config with network_use = Offline} fetcher distro slave in
    let (ready, result, _fp) = driver#solve_with_downloads reqs ~force:false ~update_local:false in
    assert (ready = true);
    Fake_system.equal_str_lists ["sha1=234"; "sha1=345"] @@ get_ids result;
  );

  "driven">:::
    try
      let root = Support.Qdom.parse_file Fake_system.real_system "driven.xml" in
      List.map make_driver_test root.Support.Qdom.child_nodes
    with Safe_exception _ as ex ->
      match Support.Utils.safe_to_string ex with
      | Some msg -> failwith msg
      | None -> assert false
]
