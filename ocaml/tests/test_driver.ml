(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit

open Support.Common
open Zeroinstall
open Zeroinstall.General

module F = Zeroinstall.Feed
module U = Support.Utils
module Q = Support.Qdom

let cache_path_for config url = Feed_cache.get_save_cache_path config url

let make_packagekit get_distro_candidates _config =
  object
    val candidates = Hashtbl.create 10

    method is_available = Lwt.return true
    method get_impls (package_name:string) : Zeroinstall.Packagekit.package_info list =
      log_info "packagekit: get_impls(%s)" package_name;
      try Hashtbl.find candidates package_name with Not_found -> []
    method check_for_candidates (package_names:string list) : unit Lwt.t =
      log_info "packagekit: check_for_candidates(%s)" (String.concat ", " package_names);
      package_names |> List.iter (fun package_name ->
        Hashtbl.replace candidates package_name (get_distro_candidates package_name)
      );
      Lwt.return ()

    method install_packages _ui _names = failwith "install_packages"
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

    method import_feed = failwith "import_feed"

    method downloader = failwith "downloader"
  end

(** Parse a test-case in driven.xml *)
let make_driver_test test_elem =
  ZI.check_tag "test" test_elem;
  let name = ZI.get_attribute "name" test_elem in
  name >:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let home = U.getenv_ex config.system "HOME" in
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
            local_path |> fake_system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
              Support.Qdom.output (Xmlm.make_output @@ `Channel ch) child
            );
    )
    | Some "requirements" ->
        let iface = ZI.get_attribute "interface" child in
        let iface =
          if U.starts_with iface "./" then home +/ iface
          else iface in
        reqs := {!reqs with
          Requirements.interface_uri = iface;
          Requirements.command = ZI.get_attribute_opt "command" child;
        };
        fails := ZI.get_attribute_opt "fails" child = Some "true";
        dry_run := ZI.get_attribute_opt "dry-run" child = Some "true";
        child |> ZI.iter ~name:"arg" (fun arg ->
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
    ZI.iter process test_elem;

    let handler =
      object
        method download_impls impls =
          ignore @@ Test_0install.handle_download_impls config expected_digests impls;
          `success

        method get_feed url =
          try `xml (StringMap.find_nf url !downloadable_feeds)
          with Not_found -> `problem "Unexpected feed requested"
      end in

    let fetcher = fake_fetcher config handler in
    let driver = Fake_system.make_driver ~fetcher config in
    let ui = Zeroinstall.Gui.Ui (Lazy.force Fake_system.null_ui) in
    let () =
      try
        Fake_system.collect_logging (fun () ->
          let sels = Fake_system.expect @@ Lwt_main.run @@ Zeroinstall.Helpers.solve_and_download_impls ui driver !reqs `Select_for_run ~refresh:false in
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
            Fake_system.assert_str_equal value (StringMap.find_safe name !actual_env)
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
      object
        method download_impls = failwith "download_impls"

        method get_feed = function
          | "http://example.com/prog.xml" -> `file (Fake_system.tests_dir +/ "prog.xml")
          | url -> failwith url
      end in
    let get_distro_candidates = function
      | "prog" ->
          Zeroinstall.Packagekit.([{
            version = Versions.parse_version "1.0";
            machine = None;
            installed = false;
            retrieval_method = {
              F.distro_size = None;
              F.distro_install_info = ("test", "prog");
            }
          }])
      | name -> failwith name in

    Zeroinstall.Packagekit.packagekit := make_packagekit get_distro_candidates;
    let distro = Distro_impls.generic_distribution config in
    let fetcher = fake_fetcher config handler in

    let driver = new Driver.driver config fetcher distro in
    let (ready, result, _fp) = driver#solve_with_downloads reqs ~force:true ~update_local:true |> Lwt_main.run in
    if not ready then
      failwith @@ Diagnostics.get_failure_reason config result;

    match result#get_selections.Q.child_nodes with
    | [ sel ] -> Fake_system.assert_str_equal "package:fallback:prog:1.0:*" (ZI.get_attribute "id" sel)
    | _ -> assert_failure "Bad selections"
      
  );

  "noNeedDl">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let foo_path = Test_0install.feed_dir +/ "Foo.xml" in
    let reqs = Requirements.({(default_requirements foo_path) with command = None}) in
    let driver = Fake_system.make_driver config in
    let ui = Zeroinstall.Gui.Ui (Lazy.force Fake_system.null_ui) in
    let sels = Zeroinstall.Helpers.solve_and_download_impls ui driver reqs `Select_for_run ~refresh:false |> Lwt_main.run in
    assert (sels <> None)
  );

  "source">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let config = {config with network_use = Full_network} in
    let import name =
      U.copy_file config.system (Test_0install.feed_dir +/ name) (cache_path_for config @@ `remote_feed ("http://foo/" ^ name)) 0o644 in
    import "Binary.xml";
    let distro =
      object (_ : Distro.distribution)
        method is_valid_package_name _ = true
        method is_installed = failwith "is_installed"
        method get_impls_for_feed ?init:_ _feed = StringMap.empty
        method check_for_candidates = raise_safe "Unexpected check_for_candidates"
        method install_distro_packages = raise_safe "install_distro_packages"
        method match_name = (=) "dummy"
      end in
    let reqs = Requirements.default_requirements "http://foo/Binary.xml" in
    let fetcher =
      object
        method download_and_import_feed (`remote_feed url) = raise_safe "download_and_import_feed: %s" url
        method download_impls = failwith "download_impls"
        method import_feed = failwith "import_feed"
        method downloader = failwith "downloader"
      end in
    let driver = new Driver.driver config fetcher distro in
    let (ready, result, _fp) = driver#solve_with_downloads reqs ~force:false ~update_local:false |> Lwt_main.run in
    assert (ready = true);

    let get_ids result =
      ZI.map result#get_selections "selection" ~f:(fun sel -> ZI.get_attribute "id" sel) in

    Fake_system.equal_str_lists ["sha1=3ce644dc725f1d21cfcf02562c76f375944b266a"] @@ get_ids result;

    (* Now ask for source instead *)
    import "Source.xml";
    import "Compiler.xml";
    let reqs = {reqs with Requirements.source = true; command = None} in
    let driver = new Driver.driver config fetcher distro in
    let (ready, result, _fp) = driver#solve_with_downloads reqs ~force:false ~update_local:false |> Lwt_main.run in
    assert (ready = true);
    Fake_system.equal_str_lists ["sha1=3ce644dc725f1d21cfcf02562c76f375944b266a"; "sha1=345"] @@ get_ids result;
  );

  "driven">:::
    let root = Support.Qdom.parse_file Fake_system.real_system "tests/driven.xml" in
    List.map make_driver_test root.Support.Qdom.child_nodes
]
