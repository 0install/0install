(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* Testing the "0install" command-line interface *)

open Zeroinstall.General
open Support.Common
open OUnit
module Q = Support.Qdom
module U = Support.Utils
module F = Zeroinstall.Feed
module FC = Zeroinstall.Feed_cache
module R = Zeroinstall.Requirements
module Escape = Zeroinstall.Escape

let assert_contains = Fake_system.assert_contains
let assert_str_equal = Fake_system.assert_str_equal
let assert_error_contains expected fn =
  Fake_system.assert_error_contains expected (fun () ->
    assert_str_equal "" @@ fn ()
  )

let test_0install = Fake_system.test_0install
let feed_dir = U.abspath Fake_system.real_system (".." +/ "tests")

exception Ok

let handle_download_impls config pending_digests impls =
  impls |> List.iter (fun impl ->
    match impl.F.impl_type with
    | F.CacheImpl {F.digests;_} ->
        if Zeroinstall.Stores.lookup_maybe config.system digests config.stores = None then (
          let digest_str =
            U.first_match digests ~f:(fun digest ->
              let digest_str = Zeroinstall.Manifest.format_digest digest in
              if StringSet.mem digest_str !pending_digests then Some digest_str else None
            ) in
          match digest_str with
          | None -> raise_safe "Digest not expected!"
          | Some digest_str ->
              pending_digests := StringSet.remove digest_str !pending_digests;
              let user_store = List.hd config.stores in
              U.makedirs config.system (user_store +/ digest_str) 0o755;
              log_info "Added %s to stores" digest_str
        )
    | _ -> assert false
  )

let impl_from_json config = (function
  | `Assoc [("id", `String id); ("from-feed", `String feed_url)] ->
      let parsed = Zeroinstall.Feed_url.parse_non_distro feed_url in
      let feed = Zeroinstall.Feed_cache.get_cached_feed config parsed |? lazy (raise_safe "Not cached: %s" feed_url) in
      StringMap.find_safe id feed.F.implementations
  | _ -> assert false
)

let expect = function
  | None -> assert_failure "Unexpected None!"
  | Some x -> x

class fake_slave _config =
  let pending_feed_downloads = ref StringMap.empty in

  let handle_download ?if_slow:_ ?size:_ ?modification_time:_ ch url =
    let contents =
      if U.starts_with url "https://keylookup.appspot.com/key/" then (
        "<key-lookup><item vote='good'>Looks legit</item></key-lookup>"
      ) else (
        StringMap.find_safe url !pending_feed_downloads
      ) in
    pending_feed_downloads := StringMap.remove url !pending_feed_downloads;
    output_string ch contents;
    `success |> Lwt.return in

  let fake_slave ?xml request =
    log_info "fake_slave: invoke: %s" (Yojson.Basic.to_string request);
    ignore xml;
    match request with
    | `List [`String "confirm-keys"; `String _url] -> assert false
    | `List [`String "unpack-archive"; `Assoc _] -> assert false
    | `List [`String "wait-for-network"] -> Some (Lwt.return (`List [`String "ok"; `String "online"]))
    | `List [`String "add-manifest-and-verify"; `String _required_digest; `String _tmpdir] ->
        Some (Lwt.return (`List [`String "ok"; `Null]))
    | _ -> None in

  object
    method install =
      Zeroinstall.Python.slave_interceptor := fake_slave;
      Zeroinstall.Downloader.interceptor := Some handle_download

    method allow_download url contents =
      pending_feed_downloads := StringMap.add url contents !pending_feed_downloads
  end

let run_0install ?stdin ?(include_stderr=false) fake_system ?(exit=0) args =
  let run = lazy (
    Fake_system.fake_log#reset;
    fake_system#set_argv @@ Array.of_list (test_0install :: args);
    Fake_system.capture_stdout ~include_stderr (fun () ->
      try Main.main (fake_system : Fake_system.fake_system :> system); assert (exit = 0)
      with System_exit n -> assert_equal ~msg:"exit code" n exit
    )
  ) in
  match stdin with
  | None -> Lazy.force run
  | Some stdin -> fake_system#with_stdin stdin run

let generic_archive = U.handle_exceptions (U.read_file Fake_system.real_system) @@ feed_dir +/ "HelloWorld.tgz"

let suite = "0install">::: [
  "select">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (_config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    fake_system#add_file (tmpdir +/ "cache" +/ "0install.net" +/ "interfaces" +/ "http%3a%2f%2fexample.com%3a8000%2fHello.xml") (feed_dir +/ "Hello.xml");
    fake_system#add_dir (tmpdir +/ "cache" +/ "0install.net" +/ "implementations") ["sha1=3ce644dc725f1d21cfcf02562c76f375944b266a"];
    fake_system#add_file "/lib/ld-linux.so.2" "/";    (* Enable multi-arch *)

    (* In --offline mode we select from the cached feed *)
    fake_system#set_argv [| test_0install; "-o"; "select"; "http://example.com:8000/Hello.xml" |];
    let output = fake_system#collect_output (fun () -> Main.main system) in
    assert (U.starts_with output "- URI: http://example.com:8000/Hello.xml");

    (* In online mode, we spawn a background process because we don't have a last-checked timestamp *)
    fake_system#set_argv [| test_0install; "select"; "http://example.com:8000/Hello.xml" |];
    let () =
      try failwith @@ fake_system#collect_output (fun () -> Main.main system)
      with Fake_system.Would_spawn (_, _, args) ->
        Fake_system.equal_str_lists
          ["update"; "--console"; "-v"; "--command"; "run"; "http://example.com:8000/Hello.xml"]
          (List.tl args) in

    (* Download succeeds (does nothing, as it's already cached *)
    fake_system#set_argv [| test_0install; "-o"; "download"; "http://example.com:8000/Hello.xml" |];
    let output = fake_system#collect_output (fun () -> Main.main system) in
    assert_str_equal "" output;

    (* Use --console --offline --refresh to force us to use the Python *)
    let my_spawn_handler args cin cout cerr =
      Fake_system.real_system#create_process args cin cout cerr in
    fake_system#set_spawn_handler (Some my_spawn_handler);
    fake_system#set_argv [| test_0install; "-cor"; "download"; "http://example.com:8000/Hello.xml"; "--version"; "2" |];
    let () =
      try Main.main system; assert false
      with Safe_exception (msg, _) ->
        assert_str_equal (
          "Can't find all required implementations:\n" ^
          "- http://example.com:8000/Hello.xml -> (problem)\n" ^
          "    User requested version 2\n" ^
          "    No usable implementations:\n" ^
          "      sha1=3ce644dc725f1d21cfcf02562c76f375944b266a (1): Excluded by user-provided restriction: version 2\n" ^
          "Note: 0install is in off-line mode") msg in
    ()
  );

  "update">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    fake_system#add_file "/lib/ld-linux.so.2" "/";    (* Enable multi-arch *)

    let run ?(exit=0) args =
      fake_system#set_argv @@ Array.of_list (test_0install :: "--console" :: args);
      fake_system#collect_output (fun () ->
        try Main.main system; assert (exit = 0)
        with System_exit n -> assert_equal ~msg:"exit code" n exit
      ) in

    Unix.putenv "DISPLAY" "";

    let out = run ~exit:1 ["update"] in
    assert (U.starts_with out "Usage:");
    assert_contains "--message" out;

    (* Updating a local feed with no dependencies *)
    let local_file = tmpdir +/ "Local.xml" in
    U.copy_file system (feed_dir +/ "Local.xml") local_file 0o644;
    let out = run ["update"; local_file] in
    assert_contains "No updates found" out;

    let fake_slave = new fake_slave config in
    fake_slave#install;

    let binary_feed = Support.Utils.read_file system (feed_dir +/ "Binary.xml") in
    let test_key = Support.Utils.read_file system (feed_dir +/ "6FCF121BE2390E0B.gpg") in

    (* Using a remote feed for the first time *)
    fake_slave#allow_download "http://example.com/Binary-1.0.tgz" generic_archive;
    fake_slave#allow_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_download "http://foo/6FCF121BE2390E0B.gpg" test_key;
    let out = run ["update"; "http://foo/Binary.xml"] in
    assert_contains "Binary.xml: new -> 1.0" out;

    (* No updates. *)
    (* todo: fails to notice that the binary is missing... *)
    fake_slave#allow_download "http://foo/Binary.xml" binary_feed;
    let out = run ["update"; "http://foo/Binary.xml"] in
    assert_contains "No updates found" out;

    (* New binary release available. *)
    let binary_feed = Support.Utils.read_file system (feed_dir +/ "Binary2.xml") in
    fake_slave#allow_download "http://foo/Binary.xml" binary_feed;
    let out = run ["update"; "http://foo/Binary.xml"] in
    assert_contains "Binary.xml: 1.0 -> 1.1" out;

    (* Compiling from source for the first time. *)
    let source_feed = U.read_file system (feed_dir +/ "Source.xml") in
    let compiler_feed = U.read_file system (feed_dir +/ "Compiler.xml") in
    fake_slave#allow_download "http://example.com/Source-1.0.tgz" generic_archive;
    fake_slave#allow_download "http://example.com/Compiler-1.0.tgz" generic_archive;
    fake_slave#allow_download "http://foo/Compiler.xml" compiler_feed;
    fake_slave#allow_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_download "http://foo/Source.xml" source_feed;
    let out = run ["update"; "http://foo/Binary.xml"; "--source"] in
    assert_contains "Binary.xml: new -> 1.0" out;
    assert_contains "Compiler.xml: new -> 1.0" out;

    (* New compiler released. *)
    let new_compiler_feed = U.read_file system (feed_dir +/ "Compiler2.xml") in
    fake_slave#allow_download "http://foo/Compiler.xml" new_compiler_feed;
    fake_slave#allow_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_download "http://foo/Source.xml" source_feed;
    let out = run ["update"; "http://foo/Binary.xml"; "--source"] in
    assert_contains "Compiler.xml: 1.0 -> 1.1" out;

    (* A dependency disappears. *)
    let new_source_feed = U.read_file system (feed_dir +/ "Source-missing-req.xml") in
    fake_slave#allow_download "http://foo/Compiler.xml" new_compiler_feed;
    fake_slave#allow_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_download "http://foo/Source.xml" new_source_feed;
    let out = run ["update"; "http://foo/Binary.xml"; "--source"] in
    assert_contains "No longer used: http://foo/Compiler.xml" out;
  );

  "download">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    let run = run_0install fake_system in

    let out = run ~exit:1 ["download"] in
    assert (U.starts_with out "Usage:");
    assert_contains "--show" out;

    let out = run ["download"; (feed_dir +/ "Local.xml"); "--show"] in
    assert_contains "Version: 0.1" out;

    let local_uri = U.abspath system (feed_dir +/ "Local.xml") in
    let out = run ["download"; local_uri; "--xml"] in
    let sels = Zeroinstall.Selections.make_selection_map @@ Q.parse_input None (Xmlm.make_input (`String (0, out))) in
    let sel = StringMap.find_safe local_uri sels in
    assert_str_equal "0.1" @@ ZI.get_attribute "version" sel;

    let () =
      try ignore @@ run ["download"; "--offline"; (feed_dir +/ "selections.xml")]; assert false
      with Safe_exception (msg, _) ->
        assert_contains "Can't download as in offline mode:\nhttp://example.com:8000/Hello.xml 1" msg in

    let fake_slave = new fake_slave config in
    fake_slave#install;
    let digest = "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" in
    fake_slave#allow_download "http://example.com:8000/HelloWorld.tgz" generic_archive;
    let out = run ["download"; (feed_dir +/ "Hello.xml"); "--show"] in
    assert_contains digest out;
    assert_contains "Version: 1\n" out;

    let out = run ["download"; "--offline"; (feed_dir +/ "selections.xml"); "--show"] in
    assert_contains digest out;
    assert_contains "Version: 1\n" out;
  );

  "download_selections">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    let run = run_0install fake_system in

    let digest = "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" in
    let fake_slave = new fake_slave config in
    fake_slave#install;
    fake_slave#allow_download "http://example.com:8000/HelloWorld.tgz" generic_archive;

    let hello = Support.Utils.read_file system (feed_dir +/ "Hello.xml") in
    let key = Support.Utils.read_file system (feed_dir +/ "6FCF121BE2390E0B.gpg") in
    fake_slave#allow_download "http://example.com:8000/Hello.xml" hello;
    fake_slave#allow_download "http://example.com:8000/6FCF121BE2390E0B.gpg" key;
    let out = run ["download"; (feed_dir +/ "selections.xml"); "--show"] in
    assert_contains digest out;
    assert_contains "Version: 1\n" out;
  );

  "display">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (_config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let run = run_0install fake_system in

    fake_system#unsetenv "DISPLAY";
    try ignore @@ run ["run"; "--gui"; "http://foo/d"]; assert false
    with Safe_exception ("Can't use GUI because $DISPLAY is not set", _) -> ();

    (* --dry-run must prevent us from using the GUI *)
    fake_system#putenv "DISPLAY" ":foo";
    let handle_download ?if_slow:_ ?size:_ ?modification_time:_ _ch url =
      assert_equal "http://foo/d" url;
      raise Ok in
    Zeroinstall.Downloader.interceptor := Some handle_download;
    try ignore @@ run ["run"; "--dry-run"; "--refresh"; "http://foo/d"]; assert false
    with Ok -> ();
  );

  "apps">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    let run = run_0install fake_system in

    fake_system#set_time @@ Fake_system.real_system#time;

    let out = run ~exit:1 ["add"; "local-app"] in
    assert (U.starts_with out "Usage:");

    let out = run ~exit:1 ["destroy"; "local-app"; "uri"] in
    assert (U.starts_with out "Usage:");

    let local_feed = feed_dir +/ "Local.xml" in

    assert_error_contains "Invalid application name 'local:app'" (fun () ->
      run ["add"; "local:app"; local_feed]
    );

    Fake_system.fake_log#reset;
    let out =
      Fake_system.collect_logging (fun () ->
        run ["add"; "--dry-run"; "local-app"; local_feed]
      ) in
    let () =
      match Fake_system.fake_log#pop_warnings with
      | [w] -> assert_contains "bin is not in $PATH. Add it with:" w
      | _ -> () in
    assert_contains "[dry-run] would write selections to " out;
    assert_contains "[dry-run] would write launcher script " out;

    Unix.mkdir (tmpdir +/ "bin") 0o700;
    fake_system#putenv "PATH" ((tmpdir +/ "bin") ^ path_sep ^ U.getenv_ex fake_system "PATH");

    let out = run ["add"; "local-app"; local_feed] in
    assert_str_equal "" out;

    assert_error_contains "Application 'local-app' already exists" (fun () ->
      run ["add"; "local-app"; local_feed]
    );

    let out = run ["man"; "--dry-run"; "local-app"] in
    assert_contains "tests/test-echo.1" out;

    fake_system#putenv "COMP_CWORD" "2";
    let out = run ["_complete"; "bash"; "0install"; "select"] in
    assert_contains "local-app" out;
    let out = run ["select"; "local-app"] in
    assert_contains "Version: 0.1" out;

    let out = run ["show"; "local-app"] in
    assert_contains "Version: 0.1" out;

    let out = run ["update"; "local-app"] in
    assert_contains "No updates found. Continuing with version 0.1." out;

    (* Run *)
    let out = run ["run"; "--dry-run"; "local-app"] in
    assert_contains "[dry-run] would execute:" out;
    assert_contains "/test-echo" out;

    (* restrictions *)
    let path = Filename.dirname @@ Generic_select.canonical_iface_uri system local_feed in
    assert_error_contains (
      Printf.sprintf (
        "Can't find all required implementations:\n" ^^
        "- %s/Local.xml -> (problem)\n" ^^
        "    User requested version 10..\n" ^^
        "    No usable implementations:\n" ^^
        "      sha1=256 (0.1): Excluded by user-provided restriction: version 10..") path)
      (fun () -> run ["update"; "local-app"; "--version=10.."]);

    let out = run ["update"; "local-app"; "--version=0.1.."] in
    assert_contains "No updates found. Continuing with version 0.1." out;

    let out = run ["select"; "local-app"] in
    assert_str_equal (Printf.sprintf (
      "User-provided restrictions in force:\n" ^^
      "  %s/Local.xml: 0.1..\n" ^^
      "\n" ^^
      "- URI: %s/Local.xml\n" ^^
      "  Version: 0.1\n" ^^
      "  Path: %s\n") path path path) out;

    (* remove restrictions [dry-run] *)
    let out = run ["update"; "--dry-run"; "local-app"; "--version-for"; path +/ "Local.xml"; ""] in
    assert_contains "No updates found. Continuing with version 0.1." out;
    assert_contains "[dry-run] would write " out;

    (* remove restrictions *)
    let out = run ["update"; "local-app"; "--version-for"; path +/ "Local.xml"; ""] in
    assert_contains "No updates found. Continuing with version 0.1." out;

    let out = run ["select"; "local-app"] in
    assert_str_equal (Printf.sprintf (
      "- URI: %s/Local.xml\n" ^^
      "  Version: 0.1\n" ^^
      "  Path: %s\n") path path) out;

    (* whatchanged *)
    fake_system#putenv "COMP_CWORD" "2";
    let out = run ["_complete"; "bash"; "0install"; "whatchanged"] in
    assert_contains "local-app" out;
    let out = run ~exit:1 ["whatchanged"; "local-app"; "uri"] in
    assert (U.starts_with out "Usage:");

    let out = run ["whatchanged"; "local-app"] in
    assert_contains "No previous history to compare against." out;

    let app = expect @@ Zeroinstall.Apps.lookup_app config "local-app" in
    let old_local = U.read_file system (app +/ "selections.xml") in
    let new_local = Str.replace_first (Str.regexp_string "0.1") "0.1-pre" old_local in
    system#atomic_write [Open_wronly; Open_binary] (app +/ "selections-2012-01-01.xml") ~mode:0o644 (fun ch ->
      output_string ch new_local
    );

    let out = run ["whatchanged"; "local-app"] in
    assert_contains "Local.xml: 0.1-pre -> 0.1" out;

    (* Allow running diff *)
    let my_spawn_handler args cin cout cerr =
      Fake_system.real_system#create_process args cin cout cerr in
    fake_system#set_spawn_handler (Some my_spawn_handler);
    let out = run ["whatchanged"; "local-app"; "--full"] in
    assert_contains "2012-01-01" out;
    fake_system#set_spawn_handler None;

    (* select detects changes *)
    let new_local = Str.replace_first (Str.regexp_string "0.1") "0.1-pre2" old_local in
    system#atomic_write [Open_wronly; Open_binary] (app +/ "selections.xml") ~mode:0o644 (fun ch ->
      output_string ch new_local
    );
    let out = run ["show"; "local-app"] in
    assert_contains "Version: 0.1-pre2" out;

    let out = run ["select"; "local-app"] in
    assert_contains "Local.xml: 0.1-pre2 -> 0.1" out;
    assert_contains "(note: use '0install update' instead to save the changes)" out;

    fake_system#putenv "COMP_CWORD" "2";
    assert_contains "local-app" @@ run ["_complete"; "bash"; "0install"; "man"];
    assert_contains "local-app" @@ run ["_complete"; "bash"; "0install"; "destroy"];
    fake_system#putenv "COMP_CWORD" "3";
    assert_str_equal "" @@ run ["_complete"; "bash"; "0install"; "destroy"];

    assert_str_equal "" @@ run ["destroy"; "local-app"];

    assert_error_contains "No such application 'local-app'" (fun () ->
      run ["destroy"; "local-app"]
    );
  );

  "add">:: Fake_system.with_tmpdir (fun tmpdir ->
    Update.wait_for_network := (fun () -> `Disconnected);

    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    let driver = Fake_system.make_driver config in
    let run = run_0install fake_system in
    config.freshness <- None;

    let out = run ["add"; "--help"] in
    assert (U.starts_with out "Usage:");

    Unix.mkdir (tmpdir +/ "bin") 0o700;
    fake_system#putenv "PATH" ((tmpdir +/ "bin") ^ path_sep ^ U.getenv_ex fake_system "PATH");

    let local_feed = feed_dir +/ "Local.xml" in
    let data_home = tmpdir +/ "data" in
    let local_copy = data_home +/ "Local.xml" in

    U.makedirs system data_home 0o700;
    U.copy_file system local_feed local_copy 0o600;

    let out = run ["add"; "local-app"; local_copy] in
    assert_str_equal "" out;

    let app = expect @@ Zeroinstall.Apps.lookup_app config "local-app" in

    (* Because the unit-tests run very quickly, we have to back-date things a bit... *)
    system#set_mtime local_copy 100.0;				(* Feed edited at t=100 *)
    system#set_mtime (app +/ "last-checked") 200.0; 	        (* Added at t=200 *)

    let distro = driver#distro in

    (* Can run without using the solver... *)
    let module A = Zeroinstall.Apps in
    let sels = A.get_selections_no_updates system app in
    assert_equal [] @@ Zeroinstall.Selections.get_unavailable_selections config ~distro sels;
    assert_equal 0.0 (A.get_times system app).A.last_solve;

    (* But if the feed is modified, we resolve... *)
    system#set_mtime local_copy 300.0;
    let sels = A.get_selections_may_update driver app in
    assert_equal [] @@ Zeroinstall.Selections.get_unavailable_selections config sels;
    assert (0.0 <> (A.get_times system app).A.last_solve);

    system#set_mtime (app +/ "last-solve") 400.0;
    let sels = A.get_selections_may_update driver app in
    assert_equal [] @@ Zeroinstall.Selections.get_unavailable_selections config ~distro sels;
    assert_equal 400.0 (A.get_times system app).A.last_solve;

    (* The feed is missing. We warn but continue with the old selections. *)
    Fake_system.collect_logging (fun () ->
      system#unlink local_copy;
      U.touch system (app +/ "last-check-attempt");	(* Prevent background update *)
      let sels = A.get_selections_may_update driver app in
      assert_equal [] @@ Zeroinstall.Selections.get_unavailable_selections config ~distro sels;
      assert (400.0 <> (A.get_times system app).A.last_solve);
    );

    fake_system#allow_spawn_detach true;
    Zeroinstall.Python.slave_interceptor := (fun ?xml:_ -> function
      | `List [`String "wait-for-network"] -> Some (Lwt.return (`List [`String "ok"; `String "offline"]))
      | _ -> None
    );
    (* Local feed is updated; now requires a download *)
    system#unlink (app +/ "last-check-attempt");
    let hello_feed = (feed_dir +/ "Hello.xml") in
    system#set_mtime (app +/ "last-solve") 400.0;
    U.copy_file system hello_feed local_copy 0o600;
    Fake_system.collect_logging (fun () ->
      Fake_system.fake_log#reset;
      ignore @@ A.get_selections_may_update driver app
    );
    let () =
      Fake_system.fake_log#assert_contains "Still not connected to network. Giving up on background update.";
      match Fake_system.fake_log#pop_warnings with
      | [ w ] -> assert_contains "Error starting background check for updates" w
      | ws -> raise_safe "Got %d warnings" (List.length ws) in

    (* Selections changed, but no download required *)
    let data = U.read_file system local_copy in
    let data = Str.replace_first (Str.regexp_string " version='1'>") " version='1.1' main='missing'>" data in
    system#atomic_write [Open_wronly; Open_binary] local_copy ~mode:0o644 (fun ch ->
      output_string ch data
    );
    system#set_mtime (app +/ "last-solve") 400.0;

    let sels = A.get_selections_may_update driver app in
    assert_equal [] @@ Zeroinstall.Selections.get_unavailable_selections config sels;

    (* If the selections.xml gets deleted, regenerate it *)
    system#unlink (app +/ "selections.xml");
    let fake_slave = new fake_slave config in
    fake_slave#install;
    fake_slave#allow_download "http://example.com:8000/HelloWorld.tgz" generic_archive;
    ignore @@ A.get_selections_may_update driver app
  );

  "add-feed">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let binary_iface = "http://foo/Binary.xml" in
    let run ?(exit=0) args =
      fake_system#set_argv @@ Array.of_list (test_0install :: "--console" :: args);
      fake_system#collect_output (fun () ->
        try Main.main config.system; assert (exit = 0)
        with System_exit n -> assert_equal ~msg:"exit code" n exit
      ) in

    assert_str_equal "(no feeds)\n" @@ run ["list-feeds"; binary_iface];

    let out = run ~exit:1 ["add-feed"] in
    assert_contains "usage:" @@ String.lowercase out;
    assert_contains "NEW-FEED" out;

    let out = fake_system#with_stdin "\n" (lazy (run ["add-feed"; (feed_dir +/ "Source.xml")])) in
    assert_contains "Add as feed for 'http://foo/Binary.xml'" out;
    let iface_config = FC.load_iface_config config binary_iface in
    assert_equal 1 @@ List.length iface_config.FC.extra_feeds;

    let out = run ["list-feeds"; binary_iface] in
    assert_contains "Source.xml" out;

    assert_contains "file\n" @@ Test_completion.do_complete fake_system "zsh" ["remove-feed"; ""] 2;
    assert_contains "Source.xml" @@ Test_completion.do_complete fake_system "zsh" ["remove-feed"; binary_iface] 3;

    let out = fake_system#with_stdin "\n" (lazy (run ["remove-feed"; (feed_dir +/ "Source.xml")])) in
    assert_contains "Remove as feed for 'http://foo/Binary.xml'" out;
    let iface_config = FC.load_iface_config config binary_iface in
    assert_equal 0 @@ List.length iface_config.FC.extra_feeds;

    (* todo: move to download tests *)
    (*
    with open('Source.xml') as stream: source_feed = stream.read()
    self.config.fetcher.allow_feed_download('http://foo/Source.xml', source_feed)
    out, err = self.run_ocaml(['add-feed', 'http://foo/Source.xml'])
    assert not err, err
    assert 'Downloading feed; please wait' in out, out
    reader.update_from_cache(binary_iface, iface_cache = self.config.iface_cache)
    assert len(binary_iface.extra_feeds) == 1
    *)
  );

  "digest">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let run args = run_0install fake_system args in
    let hw = feed_dir +/ "HelloWorld.tgz" in

    let out = run ["digest"; "--algorithm=sha1"; hw] in
    assert_str_equal "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a\n" out;

    let out = run ["digest"; "-m"; "--algorithm=sha256new"; hw] in
    assert_str_equal "D /HelloWorld\nX 4a6dfb4375ee2a63a656c8cbd6873474da67e21558f2219844f6578db8f89fca 1126963163 27 main\n" out;

    let out = run ["digest"; "-d"; "--algorithm=sha256new"; hw] in
    assert_str_equal "sha256new_RPUJPVVHEWJ673N736OCN7EMESYAEYM2UAY6OJ4MDFGUZ7QACLKA\n" out;

    let out = run ["digest"; hw] in
    assert_str_equal "sha1new=290eb133e146635fe37713fd58174324a16d595f\n" out;

    let out = run ["digest"; hw; "HelloWorld"] in
    assert_str_equal "sha1new=491678c37f77fadafbaae66b13d48d237773a68f\n" out;

    let home = U.getenv_ex config.system "HOME" in
    let tmp = U.make_tmp_dir config.system ~prefix:"0install" home in
    let out = run ["digest"; tmp] in
    assert_str_equal "sha1new=da39a3ee5e6b4b0d3255bfef95601890afd80709\n" out;
  );

  "show">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = run_0install ~exit:1 fake_system ["show"] in
    assert_contains "Usage:" out;
    assert_contains "--xml" out;

    let out = run_0install fake_system ["show"; feed_dir +/ "selections.xml"] in
    assert_contains "Version: 1\n" out;
    assert_contains "(not cached)" out;

    let out = run_0install fake_system ["show"; feed_dir +/ "selections.xml"; "-r"] in
    assert_str_equal "http://example.com:8000/Hello.xml\n" out
  );

  "select2">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let out = run_0install ~exit:1 fake_system ["select"] in
    assert_contains "Usage:" out;
    assert_contains "--xml" out;

    let out = run_0install fake_system ["select"; feed_dir +/ "Local.xml"] in
    assert_contains "Version: 0.1" out;

    let out = run_0install fake_system ["select"; feed_dir +/ "Local.xml"; "--command="] in
    assert_contains "Version: 0.1" out;

    let local_uri = U.realpath config.system (feed_dir +/ "Local.xml") in
    let out = run_0install fake_system ["select"; feed_dir +/ "Local.xml"] in
    assert_contains "Version: 0.1" out;

    let out = run_0install fake_system ["select"; feed_dir +/ "Local.xml"; "--xml"] in
    let sels = `String (0, out) |> Xmlm.make_input |> Q.parse_input (Some local_uri) in
    let index = Zeroinstall.Selections.make_selection_map sels in
    let sel = StringMap.find_safe local_uri index in
    assert_str_equal "0.1" (ZI.get_attribute "version" sel);

    let out = run_0install fake_system ["select"; feed_dir +/ "runnable/RunExec.xml"] in
    assert_contains "Runner" out;

    let local_uri = U.realpath config.system (feed_dir +/ "Hello.xml") in
    fake_system#putenv "DISPLAY" ":foo";
    let out = run_0install fake_system ["select"; "--xml"; local_uri] in
    let sels = `String (0, out) |> Xmlm.make_input |> Q.parse_input (Some local_uri) in
    let index = Zeroinstall.Selections.make_selection_map sels in
    let sel = StringMap.find_safe local_uri index in

    assert_str_equal "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" @@ ZI.get_attribute "id" sel;
  );

  "config">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let out  = run_0install fake_system ["config"; "--help"] in
    assert_contains "Usage:" out;
    assert_contains "--console" out;

    let out = run_0install fake_system ["config"] in
    assert_contains "full" out;
    assert_contains "freshness = 30d" out;
    assert_contains "help_with_testing = False" out;

    let out = run_0install fake_system ["config"; "help_with_testing"] in
    assert_str_equal "False\n" out;

    let get_value name = run_0install fake_system ["config"; name] in

    assert_str_equal "30d\n" @@ get_value "freshness";
    assert_str_equal "full\n" @@ get_value "network_use";
    assert_str_equal "False\n" @@ get_value "help_with_testing";

    assert_str_equal "" @@ run_0install fake_system ["config"; "freshness"; "5m"];
    assert_str_equal "" @@ run_0install fake_system ["config"; "help_with_testing"; "True"];
    assert_str_equal "" @@ run_0install fake_system ["config"; "network_use"; "minimal"];

    Zeroinstall.Config.load_config config;
    assert_equal (Some (5. *. 60.)) @@ config.freshness;
    assert_equal Minimal_network config.network_use;
    assert_equal true config.help_with_testing;

    assert_str_equal "" @@ run_0install fake_system ["config"; "help_with_testing"; "falsE"];
    Zeroinstall.Config.load_config config;
    assert_equal false config.help_with_testing;

    ["1s"; "2d"; "3.5m"; "4h"; "5d"] |> List.iter (fun period ->
      let secs = Conf.parse_interval period in
      assert_str_equal period @@ Conf.format_interval secs;
    )
  );
]
