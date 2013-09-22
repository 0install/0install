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
module R = Zeroinstall.Requirements
module Escape = Zeroinstall.Escape

let test_0install = Fake_system.test_0install
let feed_dir = U.abspath Fake_system.real_system (".." +/ ".." +/ "tests")

exception Ok

let handle_download_impls config pending_digests impls =
  impls |> List.iter (fun impl ->
    match impl.F.impl_type with
    | F.CacheImpl {F.digests;_} ->
        if Zeroinstall.Stores.lookup_maybe config.system digests config.stores = None then (
          let digest_str =
            U.first_match digests ~f:(fun digest ->
              let digest_str = Zeroinstall.Stores.format_digest digest in
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
      let feed = Zeroinstall.Feed_cache.get_cached_feed config feed_url |? lazy (failwith feed_url) in
      StringMap.find id feed.F.implementations
  | _ -> assert false
)

let assert_contains expected whole =
  try ignore @@ Str.search_forward (Str.regexp_string expected) whole 0
  with Not_found -> assert_failure (Printf.sprintf "Expected string '%s' not found in '%s'" expected whole)

let assert_error_contains expected (fn:unit -> string) =
  try
    Fake_system.assert_str_equal "" @@ fn ();
    assert_failure (Printf.sprintf "Expected error '%s' but got success!" expected)
  with Safe_exception (msg, _) ->
    assert_contains expected msg

let expect = function
  | None -> assert_failure "Unexpected None!"
  | Some x -> x

class fake_slave config =
  let temp_dir = List.hd config.basedirs.Support.Basedir.cache in
  let pending_feed_downloads = ref StringMap.empty in
  let pending_digests = ref StringSet.empty in
  let system = config.system in

  let handle_download_url url =
    let contents =
      try StringMap.find url !pending_feed_downloads
      with Not_found -> assert_failure url in
    pending_feed_downloads := StringMap.remove url !pending_feed_downloads;
    let tmpname = Filename.temp_file ~temp_dir "0install-" "-test" in
    system#atomic_write [Open_wronly; Open_binary] tmpname ~mode:0o644 (fun ch ->
      output_string ch contents
    );
    `List [`String "ok"; `List [`String "success"; `String tmpname]] in

  let fake_slave ?xml request =
    ignore xml;
    match request with
    | `List [`String "confirm-keys"; `String _url; `List fingerprints] ->
        assert (fingerprints <> []);
        Some (`List [`String "ok"; `List fingerprints] |> Lwt.return)
    | `List [`String "download-url"; `String url; `String _hint; timeout] ->
        let start_timeout = StringMap.find "start-timeout" !Zeroinstall.Python.handlers in
        if timeout <> `Null then
          ignore @@ start_timeout [timeout];
        Some (Lwt.return @@ handle_download_url url)
    | `List [`String "download-impls"; `List impls] ->
        impls |> List.map (impl_from_json config) |> handle_download_impls config pending_digests;
        Some (`List [`String "ok"; `List []] |> Lwt.return)
    | _ -> None in

  object
    method install =
      Zeroinstall.Python.slave_interceptor := fake_slave

    method allow_feed_download url contents =
      pending_feed_downloads := StringMap.add url contents !pending_feed_downloads

    method allow_download (hash:string) =
      pending_digests := StringSet.add hash !pending_digests
  end

let run_0install fake_system ?(exit=0) args =
  Fake_system.fake_log#reset;
  fake_system#set_argv @@ Array.of_list (test_0install :: args);
  Fake_system.capture_stdout (fun () ->
    try Main.main (fake_system :> system); assert (exit = 0)
    with System_exit n -> assert_equal ~msg:"exit code" n exit
  )

let suite = "0install">::: [
  "select">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (_config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    fake_system#add_file (tmpdir +/ "cache" +/ "0install.net" +/ "interfaces" +/ "http%3a%2f%2fexample.com%3a8000%2fHello.xml") (".." +/ ".." +/ "tests" +/ "Hello.xml");
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
    Fake_system.assert_str_equal "" output;

    (* Use --console --offline --refresh to force us to use the Python *)
    let my_spawn_handler args cin cout cerr =
      Fake_system.real_system#create_process args cin cout cerr in
    fake_system#set_spawn_handler (Some my_spawn_handler);
    fake_system#set_argv [| test_0install; "-cor"; "download"; "http://example.com:8000/Hello.xml"; "--version"; "2" |];
    let () =
      try Main.main system; assert false
      with Safe_exception (msg, _) ->
        Fake_system.assert_str_equal (
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
    U.copy_file system (".." +/ ".." +/ "tests" +/ "Local.xml") local_file 0o644;
    let out = run ["update"; local_file] in
    assert_contains "No updates found" out;

    let fake_slave = new fake_slave config in
    fake_slave#install;

    let binary_feed = Support.Utils.read_file system (feed_dir +/ "Binary.xml") in
    let test_key = Support.Utils.read_file system (feed_dir +/ "6FCF121BE2390E0B.gpg") in

    (* Using a remote feed for the first time *)
    fake_slave#allow_download "sha1=123";
    fake_slave#allow_feed_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_feed_download "http://foo/6FCF121BE2390E0B.gpg" test_key;
    let out = run ["update"; "http://foo/Binary.xml"] in
    assert_contains "Binary.xml: new -> 1.0" out;

    (* No updates. *)
    (* todo: fails to notice that the binary is missing... *)
    fake_slave#allow_feed_download "http://foo/Binary.xml" binary_feed;
    let out = run ["update"; "http://foo/Binary.xml"] in
    assert_contains "No updates found" out;

    (* New binary release available. *)
    let binary_feed = Support.Utils.read_file system (feed_dir +/ "Binary2.xml") in
    fake_slave#allow_feed_download "http://foo/Binary.xml" binary_feed;
    let out = run ["update"; "http://foo/Binary.xml"] in
    assert_contains "Binary.xml: 1.0 -> 1.1" out;

    (* Compiling from source for the first time. *)
    let source_feed = U.read_file system (feed_dir +/ "Source.xml") in
    let compiler_feed = U.read_file system (feed_dir +/ "Compiler.xml") in
    fake_slave#allow_download "sha1=234";
    fake_slave#allow_download "sha1=345";
    fake_slave#allow_feed_download "http://foo/Compiler.xml" compiler_feed;
    fake_slave#allow_feed_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_feed_download "http://foo/Source.xml" source_feed;
    let out = run ["update"; "http://foo/Binary.xml"; "--source"] in
    assert_contains "Binary.xml: new -> 1.0" out;
    assert_contains "Compiler.xml: new -> 1.0" out;

    (* New compiler released. *)
    let new_compiler_feed = U.read_file system (feed_dir +/ "Compiler2.xml") in
    fake_slave#allow_feed_download "http://foo/Compiler.xml" new_compiler_feed;
    fake_slave#allow_feed_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_feed_download "http://foo/Source.xml" source_feed;
    let out = run ["update"; "http://foo/Binary.xml"; "--source"] in
    assert_contains "Compiler.xml: 1.0 -> 1.1" out;

    (* A dependency disappears. *)
    let new_source_feed = U.read_file system (feed_dir +/ "Source-missing-req.xml") in
    fake_slave#allow_feed_download "http://foo/Compiler.xml" new_compiler_feed;
    fake_slave#allow_feed_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_feed_download "http://foo/Source.xml" new_source_feed;
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
    let sel = StringMap.find local_uri sels in
    Fake_system.assert_str_equal "0.1" @@ ZI.get_attribute "version" sel;

    let () =
      try ignore @@ run ["download"; "--offline"; (feed_dir +/ "selections.xml")]; assert false
      with Safe_exception (msg, _) ->
        assert_contains "Can't download as in offline mode:\nhttp://example.com:8000/Hello.xml 1" msg in

    let fake_slave = new fake_slave config in
    fake_slave#install;
    let digest = "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" in
    fake_slave#allow_download digest;
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
    fake_slave#allow_download digest;

    let hello = Support.Utils.read_file system (feed_dir +/ "Hello.xml") in
    let key = Support.Utils.read_file system (feed_dir +/ "6FCF121BE2390E0B.gpg") in
    fake_slave#allow_feed_download "http://example.com:8000/Hello.xml" hello;
    fake_slave#allow_feed_download "http://example.com:8000/6FCF121BE2390E0B.gpg" key;
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
    Zeroinstall.Python.slave_interceptor := (fun ?xml:_ -> function
      | `List [`String "download-url"; `String "http://foo/d"; `String _hint; `String _timeout] -> raise Ok
      | json -> failwith (Yojson.Basic.to_string json)
    );
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
      | _ -> assert false in
    assert_contains "[dry-run] would write selections to " out;
    assert_contains "[dry-run] would write launcher script " out;

    Unix.mkdir (tmpdir +/ "bin") 0o700;
    fake_system#putenv "PATH" ((tmpdir +/ "bin") ^ path_sep ^ U.getenv_ex fake_system "PATH");

    let out = run ["add"; "local-app"; local_feed] in
    Fake_system.assert_str_equal "" out;

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
    Fake_system.assert_str_equal (Printf.sprintf (
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
    Fake_system.assert_str_equal (Printf.sprintf (
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
    Fake_system.assert_str_equal "" @@ run ["_complete"; "bash"; "0install"; "destroy"];

    Fake_system.assert_str_equal "" @@ run ["destroy"; "local-app"];

    assert_error_contains "No such application 'local-app'" (fun () ->
      run ["destroy"; "local-app"]
    );
  );

  "add">:: Fake_system.with_tmpdir (fun tmpdir ->
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
    Fake_system.assert_str_equal "" out;

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
    let sels = A.get_selections_may_update driver ~use_gui:No app in
    assert_equal [] @@ Zeroinstall.Selections.get_unavailable_selections config sels;
    assert (0.0 <> (A.get_times system app).A.last_solve);

    system#set_mtime (app +/ "last-solve") 400.0;
    let sels = A.get_selections_may_update driver ~use_gui:No app in
    assert_equal [] @@ Zeroinstall.Selections.get_unavailable_selections config ~distro sels;
    assert_equal 400.0 (A.get_times system app).A.last_solve;

    (* The feed is missing. We warn but continue with the old selections. *)
    Fake_system.collect_logging (fun () ->
      system#unlink local_copy;
      U.touch system (app +/ "last-check-attempt");	(* Prevent background update *)
      let sels = A.get_selections_may_update driver ~use_gui:No app in
      assert_equal [] @@ Zeroinstall.Selections.get_unavailable_selections config ~distro sels;
      assert (400.0 <> (A.get_times system app).A.last_solve);
    );

    (* Local feed is updated; now requires a download *)
    system#unlink (app +/ "last-check-attempt");
    let hello_feed = (feed_dir +/ "Hello.xml") in
    system#set_mtime (app +/ "last-solve") 400.0;
    U.copy_file system hello_feed local_copy 0o600;
    Fake_system.collect_logging (fun () ->
      Fake_system.fake_log#reset;
      ignore @@ A.get_selections_may_update driver ~use_gui:No app
    );
    let () =
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

    let sels = A.get_selections_may_update driver ~use_gui:No app in
    assert_equal [] @@ Zeroinstall.Selections.get_unavailable_selections config sels;

    (* If the selections.xml gets deleted, regenerate it *)
    system#unlink (app +/ "selections.xml");
    let fake_slave = new fake_slave config in
    fake_slave#install;
    fake_slave#allow_download "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a";
    ignore @@ A.get_selections_may_update driver ~use_gui:No app
  );
]
