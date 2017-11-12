(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit

open Support.Common
open Zeroinstall
open Zeroinstall.General

module Impl = Zeroinstall.Impl
module F = Zeroinstall.Feed
module U = Support.Utils
module Q = Support.Qdom

let cache_path_for config url = Feed_cache.get_save_cache_path config url

let re_backslash = Str.regexp_string "\\"
let re_win_root = Str.regexp_string "c:\\root\\"

let fixup_windows_paths str =
  Str.global_replace re_win_root "/root/" str
  |> Str.global_replace re_backslash "/"

let make_packagekit get_distro_candidates =
  object (_ : Zeroinstall.Packagekit.packagekit)
    val candidates = Hashtbl.create 10

    method status = Lwt.return `Ok

    method get_impls package_name =
      log_info "packagekit: get_impls(%s)" package_name;
      let results =
        try Hashtbl.find candidates package_name with Not_found -> [] in
      { Zeroinstall.Packagekit.results; problems = [] }

    method check_for_candidates ~ui:_ ~hint (package_names:string list) : unit Lwt.t =
      log_info "packagekit: check_for_candidates(%s) for %s" (String.concat ", " package_names) hint;
      package_names |> List.iter (fun package_name ->
        Hashtbl.replace candidates package_name (get_distro_candidates package_name)
      );
      Lwt.return ()

    method install_packages _ui _names = failwith "install_packages"
  end

let fake_fetcher config handler (distro:Zeroinstall.Distro.t) =
  let fetcher =
    object
      method download_and_import_feed (`Remote_feed url) =
        match handler#get_feed url with
        | `File path ->
            let xml = U.read_file config.system path in
            let root = `String (0, xml) |> Xmlm.make_input |> Q.parse_input None |> Element.parse_feed in
            `Update (root, None) |> Lwt.return
        | `Xml root -> `Update (root, None) |> Lwt.return
        | `Problem msg -> `Problem (msg, None) |> Lwt.return

      method download_impls impls : [ `Success | `Aborted_by_user ] Lwt.t =
        handler#download_impls impls |> Lwt.return

      method import_feed = failwith "import_feed"
      method download_icon = failwith "download_icon"
      method ui = (Fake_system.null_ui :> Zeroinstall.Progress.watcher)
    end in

  object
    method config = config
    method distro = distro
    method ui = (Fake_system.null_ui :> Zeroinstall.Ui.ui_handler)
    method fetcher = fetcher
    method make_fetcher _ = fetcher
  end

(** Parse a test-case in driven.xml *)
let make_driver_test test_elem =
  ZI.check_tag "test" test_elem;
  let name = ZI.get_attribute "name" test_elem in
  name >:: Fake_system.with_tmpdir (fun tmpdir ->
    match ZI.get_attribute_opt "skip-windows" test_elem with
    | Some reason when on_windows -> skip_if true reason
    | _ ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let home = U.getenv_ex config.system "HOME" in
    let expand_tmp s =
      Str.global_replace (Str.regexp_string "@TMP@") tmpdir s in
    let reqs = ref (Zeroinstall.Requirements.run "") in
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
        let child_elem = Element.parse_feed child in
        match Element.uri child_elem with
        | Some url -> downloadable_feeds := StringMap.add url child_elem !downloadable_feeds
        | None ->
            let local_path = tmpdir +/ (ZI.get_attribute "local-path" child) in
            local_path |> fake_system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
              Support.Qdom.output (Xmlm.make_output @@ `Channel ch) child
            )
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
    | Some "problem" -> expected_problem := String.trim child.Support.Qdom.last_text_inside
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
          `Success

        method get_feed url =
          try `Xml (StringMap.find_nf url !downloadable_feeds)
          with Not_found -> `Problem "Unexpected feed requested"
      end in

    let distro = Fake_distro.make config in
    let tools = fake_fetcher config handler distro in
    let () =
      try
        Fake_system.collect_logging (fun () ->
          let sels =
            match Lwt_main.run @@ Fake_system.null_ui#run_solver tools `Select_for_run !reqs ~refresh:false with
            | `Success sels -> sels
            | `Aborted_by_user -> assert false in
          if !fails then assert_failure "Expected run_solver to fail, but it didn't!";
          let actual_env = ref StringMap.empty in
          let output = String.trim @@ Fake_system.capture_stdout (fun () ->
            let exec cmd ~env =
              ArrayLabels.iter env ~f:(fun binding ->
                let (name, value) = Support.Utils.split_pair Support.Utils.re_equals binding in
                actual_env := StringMap.add name value !actual_env
              );
              print_endline ("Would execute: " ^ Support.Logging.format_argv_for_logging cmd) in
            match Zeroinstall.Exec.execute_selections ~exec {config with dry_run = !dry_run} sels (List.rev !args) with
            | `Dry_run msg -> Zeroinstall.Dry_run.log "%s" msg
            | `Ok () -> ()
          ) in
          let output = if on_windows then fixup_windows_paths output else output in
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
    let reqs = Requirements.({(run "http://example.com/prog.xml") with command = None}) in
    let handler =
      object
        method download_impls = failwith "download_impls"

        method get_feed = function
          | "http://example.com/prog.xml" -> `File (Fake_system.tests_dir +/ "prog.xml")
          | url -> failwith url
      end in
    let get_distro_candidates = function
      | "prog" ->
          Zeroinstall.Packagekit.([{
            version = Version.parse "1.0";
            machine = None;
            installed = false;
            retrieval_method = {
              Impl.distro_size = None;
              Impl.distro_install_info = ("test", "prog");
            }
          }])
      | name -> failwith name in

    let packagekit = lazy (make_packagekit get_distro_candidates) in
    let distro = Distro_impls.generic_distribution ~packagekit config |> Distro.of_provider in
    let tools = fake_fetcher config handler distro in
    let (ready, result, _fp) = Driver.solve_with_downloads config tools#distro tools#fetcher ~watcher:tools#ui#watcher reqs ~force:true ~update_local:true |> Lwt_main.run in
    if not ready then
      failwith @@ Solver.get_failure_reason config result;

    match (Solver.selections result |> Selections.as_xml).Q.child_nodes with
    | [ sel ] -> Fake_system.assert_str_equal "package:fallback:prog:1.0:*" (ZI.get_attribute "id" sel)
    | _ -> assert_failure "Bad selections"
      
  );

  "noNeedDl">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let foo_path = Test_0install.feed_dir +/ "Foo.xml" in
    let reqs = Requirements.({(run foo_path) with command = None}) in
    let tools = Fake_system.make_tools config in
    match Fake_system.null_ui#run_solver tools `Select_for_run reqs ~refresh:false |> Lwt_main.run with
    | `Success _ -> ()
    | `Aborted_by_user -> assert false
  );

  "source">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let config = {config with network_use = Full_network} in
    let import name =
      U.copy_file config.system (Test_0install.feed_dir +/ name) (cache_path_for config @@ `Remote_feed ("http://foo/" ^ name)) 0o644 in
    import "Binary.xml";
    let distro =
      Distro.of_provider @@ object (_ : Distro.provider)
        method is_valid_package_name _ = true
        method is_installed_quick = failwith "is_installed"
        method get_impls_for_feed ?init:_ ~problem:_ _feed = StringMap.empty
        method check_for_candidates = raise_safe "Unexpected check_for_candidates"
        method install_distro_packages = raise_safe "install_distro_packages"
        method match_name = (=) "dummy"
      end in
    let reqs = Requirements.run "http://foo/Binary.xml" in
    let fetcher =
      object
        method download_and_import_feed (`Remote_feed url) = raise_safe "download_and_import_feed: %s" url
        method download_impls = failwith "download_impls"
        method import_feed = failwith "import_feed"
        method download_icon = failwith "download_icon"
        method ui = (Fake_system.null_ui :> Zeroinstall.Progress.watcher)
      end in
    let (ready, result, _fp) = Driver.solve_with_downloads config distro fetcher ~watcher:Fake_system.null_ui#watcher reqs ~force:false ~update_local:false |> Lwt_main.run in
    assert (ready = true);

    let get_ids result = Selections.as_xml (Solver.selections result)
      |> ZI.map ~name:"selection" (ZI.get_attribute "id") in

    Fake_system.equal_str_lists ["sha1=3ce644dc725f1d21cfcf02562c76f375944b266a"] @@ get_ids result;

    (* Now ask for source instead *)
    import "Source.xml";
    import "Compiler.xml";
    let reqs = {reqs with Requirements.source = true; command = None} in
    let (ready, result, _fp) = Driver.solve_with_downloads config distro fetcher ~watcher:Fake_system.null_ui#watcher reqs ~force:false ~update_local:false |> Lwt_main.run in
    assert (ready = true);
    Fake_system.equal_str_lists ["sha1=3ce644dc725f1d21cfcf02562c76f375944b266a"; "sha1=345"] @@ get_ids result;
  );

  "driven">:::
    let root = Support.Qdom.parse_file Fake_system.real_system "tests/driven.xml" in
    List.map make_driver_test root.Support.Qdom.child_nodes
]
