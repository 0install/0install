(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* Testing the "0install" command-line interface *)

open Zeroinstall.General
open Zeroinstall
open Support
open Support.Common
open OUnit
module Impl = Zeroinstall.Impl
module Q = Support.Qdom
module U = Support.Utils
module F = Zeroinstall.Feed
module FC = Zeroinstall.Feed_cache
module R = Zeroinstall.Requirements
module Escape = Zeroinstall.Escape
module Selections = Zeroinstall.Selections

let assert_contains = Fake_system.assert_contains
let assert_str_equal = Fake_system.assert_str_equal
let assert_error_contains expected fn =
  Fake_system.assert_error_contains expected (fun () ->
    assert_str_equal "" @@ fn ()
  )

let test_0install = Fake_system.test_0install

exception Ok

let handle_download_impls config pending_digests impls =
  impls |> List.iter (fun impl ->
    match impl.Impl.impl_type with
    | `Cache_impl {Impl.digests;_} ->
        if Zeroinstall.Stores.lookup_maybe config.system digests config.stores = None then (
          let digest_str =
            digests |> U.first_match (fun digest ->
              let digest_str = Zeroinstall.Manifest.format_digest digest in
              if XString.Set.mem digest_str !pending_digests then Some digest_str else None
            ) in
          match digest_str with
          | None -> Safe_exn.failf "Digest not expected!"
          | Some digest_str ->
              pending_digests := XString.Set.remove digest_str !pending_digests;
              let user_store = List.hd config.stores in
              U.makedirs config.system (user_store +/ digest_str) 0o755;
              log_info "Added %s to stores" digest_str
        )
    | _ -> assert false
  )

let impl_from_json config = (function
  | `Assoc [("id", `String id); ("from-feed", `String feed_url)] ->
      let parsed = Zeroinstall.Feed_url.parse_non_distro feed_url in
      let feed = Zeroinstall.Feed_cache.get_cached_feed config parsed |? lazy (Safe_exn.failf "Not cached: %s" feed_url) in
      XString.Map.find_safe id (F.zi_implementations feed)
  | _ -> assert false
)

let expect = function
  | None -> assert_failure "Unexpected None!"
  | Some x -> x

let write_script (system:#system) launcher_script interface_uri =
  launcher_script |> system#with_open_out [Open_wronly;Open_creat] ~mode:0o755 (fun ch ->
    Printf.fprintf ch "#!/bin/sh\nexec 0launch '%s' \"$@\"\n" interface_uri
  )

class fake_slave _config =
  let pending_feed_downloads = ref XString.Map.empty in

  let handle_download ?if_slow:_ ?size:_ ?modification_time:_ ch url =
    let contents =
      if XString.starts_with url "https://keylookup.0install.net/key/" then (
        "<key-lookup><item vote='good'>Looks legit</item></key-lookup>"
      ) else (
        XString.Map.find_safe url !pending_feed_downloads
      ) in
    pending_feed_downloads := XString.Map.remove url !pending_feed_downloads;
    output_string ch contents;
    `Success |> Lwt.return in

  object
    method install =
      Zeroinstall.Downloader.interceptor := Some handle_download

    method allow_download url contents =
      pending_feed_downloads := XString.Map.add url contents !pending_feed_downloads
  end

let run_0install ?stdin ?(binary=test_0install) ?(include_stderr=false) fake_system ?(exit=0) args =
  let run = lazy (
    Fake_system.fake_log#reset;
    fake_system#set_argv @@ Array.of_list (binary :: args);
    Fake_system.capture_stdout ~include_stderr (fun () ->
        let stdout = Format.std_formatter in
        try Main.main ~stdout (fake_system : Fake_system.fake_system :> system); assert (exit = 0)
        with System_exit n -> assert_equal ~msg:"exit code" n exit
    )
  ) in
  match stdin with
  | None -> Lazy.force run
  | Some stdin -> fake_system#with_stdin stdin run

let check_man fake_system args expected =
  try
    run_0install fake_system ("man" :: args) |> ignore;
    assert false
  with Fake_system.Would_exec (true, _env, man_args) ->
    let man_args =
      match man_args with
      | [prog; arg] when Str.string_match (Str.regexp "^.*/\\(tests/.*\\)$") arg 0 ->
          let rel_path = Str.matched_group 1 arg in
          [prog; rel_path]
      | x -> x in
    Fake_system.equal_str_lists expected man_args

let generic_archive = U.handle_exceptions (U.read_file Fake_system.real_system) @@ Fake_system.test_data "HelloWorld.tgz"

let selections_of_string ?path s =
  `String (0, s) |> Xmlm.make_input |> Q.parse_input path |> Selections.create

let suite = "0install">::: [
  "select">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (_config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    fake_system#add_file (tmpdir +/ "cache" +/ "interfaces" +/ "http%3a%2f%2fexample.com%3a8000%2fHello.xml") (Fake_system.test_data "Hello.xml");
    fake_system#add_dir (tmpdir +/ "cache" +/ "implementations") ["sha1=3ce644dc725f1d21cfcf02562c76f375944b266a"];
    fake_system#add_file "/lib/ld-linux.so.2" "/";    (* Enable multi-arch *)

    (* In --offline mode we select from the cached feed *)
    fake_system#set_argv [| test_0install; "-o"; "select"; "http://example.com:8000/Hello.xml" |];
    let output = Fake_system.collect_output (fun stdout -> Main.main ~stdout system) in
    assert (XString.starts_with output "- URI: http://example.com:8000/Hello.xml");

    (* In online mode, we spawn a background process because we don't have a last-checked timestamp *)
    fake_system#set_argv [| test_0install; "select"; "http://example.com:8000/Hello.xml" |];
    let () =
      try failwith @@ Fake_system.collect_output (fun stdout -> Main.main ~stdout system)
      with Fake_system.Would_spawn (_, _, args) ->
        Fake_system.equal_str_lists
         ["select"; "--refresh"; "--console"; "-v"; "--command"; "run"; "http://example.com:8000/Hello.xml"]
          (List.tl args) in

    (* Download succeeds (does nothing, as it's already cached *)
    fake_system#set_argv [| test_0install; "-o"; "download"; "http://example.com:8000/Hello.xml" |];
    let output = Fake_system.collect_output (fun stdout -> Main.main ~stdout system) in
    assert_str_equal "" output;

    (* Use --console --offline --refresh to force us to use the Python *)
    let my_spawn_handler ?env:_ args cin cout cerr =
      Fake_system.real_system#create_process args cin cout cerr in
    fake_system#set_spawn_handler (Some my_spawn_handler);
    fake_system#set_argv [| test_0install; "-cor"; "download"; "http://example.com:8000/Hello.xml"; "--version"; "2" |];
    let () =
      try Fake_system.check_no_output (fun stdout -> Main.main ~stdout system); assert false
      with Safe_exn.T e ->
        let msg = Safe_exn.msg e in
        assert_str_equal (
          "Can't find all required implementations:\n" ^
          "- http://example.com:8000/Hello.xml -> (problem)\n" ^
          "    User requested version 2\n" ^
          "    No usable implementations:\n" ^
          "      v1 (sha1=3ce644dc725f...): Excluded by user-provided restriction: version 2\n" ^
          "Note: 0install is in off-line mode") msg in
    ()
  );

  "update">:: Fake_gpg_agent.with_gpg (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    fake_system#add_file "/lib/ld-linux.so.2" "/";    (* Enable multi-arch *)

    let run ?(exit=0) args =
      fake_system#set_argv @@ Array.of_list (test_0install :: "--console" :: args);
      Fake_system.collect_output (fun stdout ->
        try Main.main ~stdout system; assert (exit = 0)
        with System_exit n -> assert_equal ~msg:"exit code" n exit
      ) in

    Unix.putenv "DISPLAY" "";

    let out = run ~exit:1 ["update"] in
    assert (XString.starts_with out "Usage:");
    assert_contains "--message" out;

    (* Updating a local feed with no dependencies *)
    let local_file = tmpdir +/ "Local.xml" in
    U.copy_file system (Fake_system.test_data "Local.xml") local_file 0o644;
    let out = run ["update"; local_file] in
    assert_contains "No updates found" out;

    let fake_slave = new fake_slave config in
    fake_slave#install;

    let binary_feed = Support.Utils.read_file system (Fake_system.test_data "Binary.xml") in
    let test_key = Support.Utils.read_file system (Fake_system.test_data "6FCF121BE2390E0B.gpg") in

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
    let binary_feed = Support.Utils.read_file system (Fake_system.test_data "Binary2.xml") in
    fake_slave#allow_download "http://foo/Binary.xml" binary_feed;
    let out = run ["update"; "http://foo/Binary.xml"] in
    assert_contains "Binary.xml: 1.0 -> 1.1" out;

    (* Compiling from source for the first time. *)
    let source_feed = U.read_file system (Fake_system.test_data "Source.xml") in
    let compiler_feed = U.read_file system (Fake_system.test_data "Compiler.xml") in
    fake_slave#allow_download "http://example.com/Source-1.0.tgz" generic_archive;
    fake_slave#allow_download "http://example.com/Compiler-1.0.tgz" generic_archive;
    fake_slave#allow_download "http://foo/Compiler.xml" compiler_feed;
    fake_slave#allow_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_download "http://foo/Source.xml" source_feed;
    let out = run ["update"; "http://foo/Binary.xml"; "--source"] in
    assert_contains "Binary.xml#source: new -> 1.0" out;
    assert_contains "Compiler.xml: new -> 1.0" out;

    (* New compiler released. *)
    let new_compiler_feed = U.read_file system (Fake_system.test_data "Compiler2.xml") in
    fake_slave#allow_download "http://foo/Compiler.xml" new_compiler_feed;
    fake_slave#allow_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_download "http://foo/Source.xml" source_feed;
    let out = run ["update"; "http://foo/Binary.xml"; "--source"] in
    assert_contains "Compiler.xml: 1.0 -> 1.1" out;

    (* A dependency disappears. *)
    let new_source_feed = U.read_file system (Fake_system.test_data "Source-missing-req.xml") in
    fake_slave#allow_download "http://foo/Compiler.xml" new_compiler_feed;
    fake_slave#allow_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_download "http://foo/Source.xml" new_source_feed;
    let out = run ["update"; "http://foo/Binary.xml"; "--source"] in
    assert_contains "No longer used: http://foo/Compiler.xml" out;
  );

  "download">:: Fake_system.with_tmpdir (fun tmpdir ->
    skip_if on_windows "Uses tar";
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    let run = run_0install fake_system in

    let out = run ~exit:1 ["download"] in
    assert (XString.starts_with out "Usage:");
    assert_contains "--show" out;

    let out = run ["download"; (Fake_system.test_data "Local.xml"); "--show"] in
    assert_contains "Version: 0.1" out;

    let local_uri = U.abspath system (Fake_system.test_data "Local.xml") in
    let out = run ["download"; local_uri; "--xml"] in
    let sels = selections_of_string out in
    let sel = Selections.(get_selected_ex {iface = local_uri; source = false}) sels in
    assert_str_equal "0.1" @@ Element.version sel;

    let () =
      try ignore @@ run ["download"; "--offline"; (Fake_system.test_data "selections.xml")]; assert false
      with Safe_exn.T e ->
        let msg = Safe_exn.msg e in
        assert_contains "Can't download as in offline mode:\nhttp://example.com:8000/Hello.xml 1" msg in

    let fake_slave = new fake_slave config in
    fake_slave#install;
    let digest = "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" in
    fake_slave#allow_download "http://example.com:8000/HelloWorld.tgz" generic_archive;
    let out = run ["download"; (Fake_system.test_data "Hello.xml"); "--show"] in
    assert_contains digest out;
    assert_contains "Version: 1\n" out;

    let out = run ["download"; "--offline"; (Fake_system.test_data "selections.xml"); "--show"] in
    assert_contains digest out;
    assert_contains "Version: 1\n" out;
  );

  "download_selections">:: Fake_gpg_agent.with_gpg (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    let run = run_0install fake_system in

    let digest = "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" in
    let fake_slave = new fake_slave config in
    fake_slave#install;
    fake_slave#allow_download "http://example.com:8000/HelloWorld.tgz" generic_archive;

    let hello = Support.Utils.read_file system (Fake_system.test_data "Hello.xml") in
    let key = Support.Utils.read_file system (Fake_system.test_data "6FCF121BE2390E0B.gpg") in
    fake_slave#allow_download "http://example.com:8000/Hello.xml" hello;
    fake_slave#allow_download "http://example.com:8000/6FCF121BE2390E0B.gpg" key;
    let out = run ["download"; (Fake_system.test_data "selections.xml"); "--show"] in
    assert_contains digest out;
    assert_contains "Version: 1\n" out
  );

  "display">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (_config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let run = run_0install fake_system in

    fake_system#unsetenv "DISPLAY";
    try ignore @@ run ["run"; "--gui"; "http://foo/d"]; assert false
    with Safe_exn.T e when Safe_exn.msg e = "Can't use GUI because $DISPLAY is not set" -> ();

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
    skip_if on_windows "Needs user bin directory in $PATH";
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    let run = run_0install fake_system in

    fake_system#set_time @@ Fake_system.real_system#time;

    let out = run ~exit:1 ["add"; "local-app"] in
    assert (XString.starts_with out "Usage:");

    let out = run ~exit:1 ["destroy"; "local-app"; "uri"] in
    assert (XString.starts_with out "Usage:");

    let local_feed = Fake_system.test_data "Local.xml" in

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

    let bin_dir = (tmpdir +/ "bin") in
    assert (not (fake_system#file_exists bin_dir));

    let out = run ["add"; "local-app-make-bin"; local_feed] in
    assert_str_equal "" out;

    assert (fake_system#file_exists bin_dir);

    let out = run ["add"; "local-app"; local_feed] in
    assert_str_equal "" out;

    assert_error_contains "Application 'local-app' already exists" (fun () ->
      run ["add"; "local-app"; local_feed]
    );

    let out = run ["man"; "--dry-run"; "local-app"] in
    assert_contains "data/test-echo.1" out;

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
        "      v0.1 (sha1=256): Excluded by user-provided restriction: version 10..") path)
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
    assert (XString.starts_with out "Usage:");

    let out = run ["whatchanged"; "local-app"] in
    assert_contains "No previous history to compare against." out;

    let app = expect @@ Zeroinstall.Apps.lookup_app config "local-app" in
    let old_local = U.read_file system (app +/ "selections.xml") in
    let new_local = Str.replace_first (Str.regexp "version=.0\\.1.") "version='0.1-pre'" old_local in
    app +/ "selections-2012-01-01.xml" |> system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
      output_string ch new_local
    );

    let out = run ["whatchanged"; "local-app"] in
    assert_contains "Local.xml: 0.1-pre -> 0.1" out;

    (* Allow running diff *)
    let my_spawn_handler ?env:_ args cin cout cerr =
      Fake_system.real_system#create_process args cin cout cerr in
    fake_system#set_spawn_handler (Some my_spawn_handler);
    let out = run ["whatchanged"; "local-app"; "--full"] in
    assert_contains "2012-01-01" out;
    fake_system#set_spawn_handler None;

    (* select detects changes *)
    let new_local = Str.replace_first (Str.regexp "version=.0\\.1.") "version='0.1-pre2'" old_local in
    app +/ "selections.xml" |> system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
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
    skip_if on_windows "Time doesn't work on Windows";
    Update.wait_for_network := (fun () -> `Disconnected);

    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    let tools = Fake_system.make_tools config in
    let run = run_0install fake_system in
    config.freshness <- None;

    let out = run ["add"; "--help"] in
    assert (XString.starts_with out "Usage:");

    Unix.mkdir (tmpdir +/ "bin") 0o700;
    fake_system#putenv "PATH" ((tmpdir +/ "bin") ^ path_sep ^ U.getenv_ex fake_system "PATH");

    let local_feed = Fake_system.test_data "Local.xml" in
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

    let distro = tools#distro in

    (* Can run without using the solver... *)
    let module A = Zeroinstall.Apps in
    let sels = A.get_selections_no_updates system app in
    assert_equal [] @@ Zeroinstall.Driver.get_unavailable_selections config ~distro sels;
    assert_equal 0.0 (A.get_times system app).A.last_solve;

    (* But if the feed is modified, we resolve... *)
    system#set_mtime local_copy 300.0;
    let sels = A.get_selections_may_update tools app |> Lwt_main.run in
    assert_equal [] @@ Zeroinstall.Driver.get_unavailable_selections config sels;
    assert (0.0 <> (A.get_times system app).A.last_solve);

    system#set_mtime (app +/ "last-solve") 400.0;
    let sels = A.get_selections_may_update tools app |> Lwt_main.run in
    let printer xs =
      let pp_sep f () = Format.pp_print_string f "; " in
      Format.asprintf "[%a]" (Format.pp_print_list ~pp_sep Element.pp) xs
    in
    assert_equal ~printer [] @@ Zeroinstall.Driver.get_unavailable_selections config ~distro sels;
    assert_equal 400.0 (A.get_times system app).A.last_solve;

    (* The feed is missing. We warn but continue with the old selections. *)
    Fake_system.collect_logging (fun () ->
      system#unlink local_copy;
      U.touch system (app +/ "last-check-attempt");	(* Prevent background update *)
      let sels = A.get_selections_may_update tools app |> Lwt_main.run in
      assert_equal [] @@ Zeroinstall.Driver.get_unavailable_selections config ~distro sels;
      assert (400.0 <> (A.get_times system app).A.last_solve);
    );

    fake_system#allow_spawn_detach true;
    (* Local feed is updated; now requires a download *)
    system#unlink (app +/ "last-check-attempt");
    let hello_feed = (Fake_system.test_data "Hello.xml") in
    system#set_mtime (app +/ "last-solve") 400.0;
    U.copy_file system hello_feed local_copy 0o600;
    Fake_system.collect_logging (fun () ->
      Fake_system.fake_log#reset;
      A.get_selections_may_update tools app |> Lwt_main.run |> ignore
    );
    let () =
      Fake_system.fake_log#assert_contains "Still not connected to network. Giving up on background update.";
      match Fake_system.fake_log#pop_warnings with
      | [ w ] -> assert_contains "Error starting background check for updates" w
      | ws -> Safe_exn.failf "Got %d warnings" (List.length ws) in

    (* Selections changed, but no download required *)
    let data = U.read_file system local_copy in
    let data = Str.replace_first (Str.regexp_string " version='1'>") " version='1.1' main='missing'>" data in
    local_copy |> system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
      output_string ch data
    );
    system#set_mtime (app +/ "last-solve") 400.0;

    let sels = A.get_selections_may_update tools app |> Lwt_main.run in
    assert_equal [] @@ Zeroinstall.Driver.get_unavailable_selections config sels;

    (* If the selections.xml gets deleted, regenerate it *)
    system#unlink (app +/ "selections.xml");
    let fake_slave = new fake_slave config in
    fake_slave#install;
    fake_slave#allow_download "http://example.com:8000/HelloWorld.tgz" generic_archive;
    A.get_selections_may_update tools app |> Lwt_main.run |> ignore
  );

  "add-feed">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if on_windows "Stdin FD tricks won't work";
    let binary_iface = "http://foo/Binary.xml" in
    let run ?(exit=0) args =
      fake_system#set_argv @@ Array.of_list (test_0install :: "--console" :: args);
      Fake_system.collect_output (fun stdout ->
        try Main.main ~stdout config.system; assert (exit = 0)
        with System_exit n -> assert_equal ~msg:"exit code" n exit
      ) in

    assert_str_equal "(no feeds)\n" @@ run ["list-feeds"; binary_iface];

    let out = run ~exit:1 ["add-feed"] in
    assert_contains "usage:" @@ String.lowercase_ascii out;
    assert_contains "NEW-FEED" out;

    let out = fake_system#with_stdin "\n" (lazy (run ["add-feed"; (Fake_system.test_data "Source.xml")])) in
    assert_contains "Add as feed for 'http://foo/Binary.xml'" out;
    let iface_config = FC.load_iface_config config binary_iface in
    assert_equal 1 @@ List.length iface_config.FC.extra_feeds;

    let out = run ["list-feeds"; binary_iface] in
    assert_contains "Source.xml" out;

    assert_contains "file\n" @@ Test_completion.do_complete fake_system "zsh" ["remove-feed"; ""] 2;
    assert_contains "Source.xml" @@ Test_completion.do_complete fake_system "zsh" ["remove-feed"; binary_iface] 3;

    let out = fake_system#with_stdin "\n" (lazy (run ["remove-feed"; (Fake_system.test_data "Source.xml")])) in
    assert_contains "Remove as feed for 'http://foo/Binary.xml'" out;
    let iface_config = FC.load_iface_config config binary_iface in
    assert_equal 0 @@ List.length iface_config.FC.extra_feeds;

    let tmp_feed, ch = Filename.open_temp_file "0install-" "-test-feed" in
    Fake_system.test_data "Source.xml" |> fake_system#with_open_in [Open_binary] (fun source_ch ->
      U.copy_channel source_ch ch;
    );
    close_out ch;
    let out = run ["add-feed"; binary_iface; tmp_feed] in
    assert_str_equal "" out;
    Unix.chmod tmp_feed 0o600;
    Unix.unlink tmp_feed;
    let out = run ["remove-feed"; binary_iface; tmp_feed] in
    assert_str_equal "" out;

    (* todo: move to download tests *)
    (*
    with open('Source.xml') as stream: source_feed = stream.read()
    self.config.fetcher.allow_feed_download('http://foo/Source.xml', source_feed)
    let out = run_0install fake_system ['add-feed', 'http://foo/Source.xml'])
    assert 'Downloading feed; please wait' in out, out
    reader.update_from_cache(binary_iface, iface_cache = self.config.iface_cache)
    assert len(binary_iface.extra_feeds) == 1
    *)
  );

  "digest">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if on_windows "Uses tar";
    let run args = run_0install fake_system args in
    let hw = Fake_system.test_data "HelloWorld.tgz" in

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

    let out = run_0install fake_system ["show"; Fake_system.test_data "selections.xml"] in
    assert_contains "Version: 1\n" out;
    assert_contains "(not cached)" out;

    let out = run_0install fake_system ["show"; Fake_system.test_data "selections.xml"; "-r"] in
    assert_str_equal "http://example.com:8000/Hello.xml\n" out
  );

  "select2">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let out = run_0install ~exit:1 fake_system ["select"] in
    assert_contains "Usage:" out;
    assert_contains "--xml" out;

    let out = run_0install fake_system ["select"; Fake_system.test_data "Local.xml"] in
    assert_contains "Version: 0.1" out;

    let out = run_0install fake_system ["select"; Fake_system.test_data "Local.xml"; "--command="] in
    assert_contains "Version: 0.1" out;

    let local_uri = U.realpath config.system (Fake_system.test_data "Local.xml") in
    let out = run_0install fake_system ["select"; Fake_system.test_data "Local.xml"] in
    assert_contains "Version: 0.1" out;

    let out = run_0install fake_system ["select"; Fake_system.test_data "Local.xml"; "--xml"] in
    let sels = selections_of_string ~path:local_uri out in
    let sel = Selections.(get_selected_ex {iface = local_uri; source = false}) sels in
    assert_str_equal "0.1" (Element.version sel);

    let out = run_0install fake_system ["select"; Fake_system.test_data "runnable/RunExec.xml"] in
    assert_contains "Runner" out;

    let local_uri = U.realpath config.system (Fake_system.test_data "Hello.xml") in
    fake_system#putenv "DISPLAY" ":foo";
    let out = run_0install fake_system ["select"; "--xml"; local_uri] in
    let sels = selections_of_string ~path:local_uri out in
    let sel = Selections.(get_selected_ex {iface = local_uri; source = false}) sels in

    assert_str_equal "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" @@ Element.id sel;
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

    let injector_dir = fake_system#tmpdir +/ "config/injector" in
    assert_equal ~msg:"init no config" false (fake_system#file_exists injector_dir);

    let out = run_0install fake_system ["config"; "--dry-run"; "help_with_testing"; "false"] in
    Fake_system.assert_matches "^\\[dry-run] Would write config to .*config..?injector..?global" out;
    Zeroinstall.Config.load_config config;
    assert_equal false config.help_with_testing;
    assert_equal ~msg:"no config dir created" false (fake_system#file_exists injector_dir);

    assert_str_equal "30d\n" @@ get_value "freshness";
    assert_str_equal "full\n" @@ get_value "network_use";
    assert_str_equal "False\n" @@ get_value "help_with_testing";

    assert_str_equal "" @@ run_0install fake_system ["config"; "freshness"; "5m"];
    assert_str_equal "" @@ run_0install fake_system ["config"; "help_with_testing"; "True"];
    assert_str_equal "" @@ run_0install fake_system ["config"; "network_use"; "minimal"];

    assert_equal ~msg:"config dir exists" true (fake_system#file_exists injector_dir);

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

  "import">:: Fake_gpg_agent.with_gpg (fun tmpdir ->
    let config, fake_system = Fake_system.get_fake_config (Some tmpdir) in
    config.auto_approve_keys <- false;
    config.key_info_server <- None;
    Zeroinstall.Config.save_config config;

    let out = run_0install ~exit:1 fake_system ["import"] in
    assert_contains "Usage:" out;
    assert_contains "FEED" out;

    let gpg = Support.Gpg.make config.system in
    Lwt_main.run @@ Support.Gpg.import_key gpg (U.read_file config.system (Fake_system.test_data "6FCF121BE2390E0B.gpg"));
    let out = run_0install fake_system ~include_stderr:true ["import"; Fake_system.test_data "Hello.xml"] ~stdin:"Y\n" in
    assert_contains "Do you want to trust this key to sign feeds from 'example.com:8000'?" out;
    Fake_system.fake_log#assert_contains "Trusting DE937DD411906ACF7C263B396FCF121BE2390E0B for example.com:8000"
  );

  "list">:: Fake_gpg_agent.with_gpg (fun tmpdir ->
    let config, fake_system = Fake_system.get_fake_config (Some tmpdir) in
    config.auto_approve_keys <- false;
    config.key_info_server <- None;
    Zeroinstall.Config.save_config config;

    let out = run_0install ~exit:1 fake_system ["list"; "foo"; "bar"] in
    assert_contains "Usage:" out;
    assert_contains "PATTERN" out;

    let out = run_0install fake_system ["list"] in
    assert_str_equal "" out;

    let gpg = Support.Gpg.make config.system in
    Lwt_main.run @@ Support.Gpg.import_key gpg (U.read_file config.system (Fake_system.test_data "6FCF121BE2390E0B.gpg"));
    ignore @@ run_0install fake_system ~include_stderr:true ["import"; Fake_system.test_data "Hello.xml"] ~stdin:"Y\n";

    let out = run_0install fake_system ["list"] in
    assert_str_equal "http://example.com:8000/Hello.xml\n" out;

    let out = run_0install fake_system ["list"; "foo"] in
    assert_str_equal "" out;

    let out = run_0install fake_system ["list"; "hello"] in
    assert_str_equal "http://example.com:8000/Hello.xml\n" out
  );

  "help">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = run_0install ~exit:1 fake_system [] in
    assert (XString.starts_with out "Usage:")
  );

  "list2">:: Fake_system.with_fake_config ~portable_base:false (fun (config, fake_system) ->
    let out = run_0install fake_system ["list"] in
    assert_str_equal "" out;
    let basedirs = Support.Basedir.get_default_config config.system in
    let cached_ifaces = List.hd basedirs.Support.Basedir.cache +/ "0install.net" +/ "interfaces" in

    U.makedirs config.system cached_ifaces 0o700;
    U.touch config.system @@ cached_ifaces +/ "file%3a%2f%2ffoo";

    let out = run_0install fake_system ["list"] in
    assert_str_equal "file://foo\n" out;

    let out = run_0install fake_system ["list"; "foo"] in
    assert_str_equal "file://foo\n" out;

    let out = run_0install fake_system ["list"; "bar"] in
    assert_str_equal "" out;

    let out = run_0install fake_system ~exit:1 ["list"; "one"; "two"] in
    assert (XString.starts_with out "Usage:");
  );

  "version">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = run_0install fake_system ~binary:"0launch" ["--version"] in
    assert (XString.starts_with out "0launch (zero-install)");
  );

  "invalid">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    Fake_system.assert_raises_safe "Unknown option '-q'" (lazy (
      run_0install fake_system ~binary:"0launch" ["-q"; "/missing"] |> ignore
    ));
  );

  "run">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    Fake_system.assert_raises_safe ".*test-echo' does not exist" (lazy (
      run_0install fake_system ~binary:"0launch" [Fake_system.test_data "Local.xml"] |> ignore
    ));
  );

  "abs-main">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let name, ch = Filename.open_temp_file ~temp_dir:fake_system#tmpdir "abs-main" "tmp" in
    output_string ch
      "<?xml version='1.0' ?>\
      \n<interface last-modified='1110752708'\
      \n uri='http://foo'\
      \n xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>\
      \n  <name>Foo</name>\
      \n  <summary>Foo</summary>\
      \n  <description>Foo</description>\
      \n  <group main='/bin/sh'>\
      \n   <implementation id='.' version='1'/>\
      \n  </group>\
      \n</interface>";
    close_out ch;

    Fake_system.assert_raises_safe "Absolute path '/bin/sh' in <group>" (lazy (
      run_0install fake_system ~exit:1 ["run"; name] |> ignore
    ));
  );

  "offline">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    Fake_system.assert_raises_safe
     "Can't find all required implementations:\
    \n- http://foo/d -> (problem)\
    \n    Main feed 'http://foo/d' not available\
    \n    No known implementations at all\
    \nNote: 0install is in off-line mode"
     (lazy (run_0install fake_system ~binary:"0launch" ["--offline"; "http://foo/d"] |> ignore));
  );

  "need-download">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    fake_system#putenv "DISPLAY" ":foo";
    let out = run_0install fake_system ["download"; "--dry-run"; Fake_system.test_data "Foo.xml"] in
    assert_str_equal "" out;
  );

  "hello">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = run_0install fake_system ~binary:"0launch" ["--dry-run"; Fake_system.test_data "Foo.xml"] in
    assert_contains "[dry-run] would execute: " out;

    try run_0install fake_system ~binary:"0launch" ~exit:127 [Fake_system.test_data "Foo.xml"] |> ignore
    with Fake_system.Would_exec (false, _env, [path]) ->
      assert_contains "tests" path;
  );

  "ranges">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = run_0install fake_system ["select"; "--before=1"; "--not-before=0.2"; Fake_system.test_data "Foo.xml"] in
    if on_windows then assert_contains "data\\rpm" out
    else assert_contains "data/rpm" out;
  );

  "logging">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = run_0install fake_system ["-v"; "list"; "UNKNOWN"] in
    assert_str_equal "" out;
    Fake_system.fake_log#assert_contains "0install .* (OCaml version): verbose mode on";
  );

  "help2">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = run_0install fake_system ~binary:"0launch" ["--help"] in
    assert_contains "Options:" out;

    let out = run_0install fake_system ~exit:1 ~binary:"0launch" [] in
    assert_contains "Options:" out;
  );

  "bad-fd">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let copy = Unix.dup Unix.stdout in
    U.finally_do (fun () -> Unix.dup2 copy Unix.stdout) ()
      (fun () ->
        Unix.close Unix.stdout;
        let out = run_0install fake_system ["list"; "UNKNOWN"] in
        assert_str_equal "" out
      )
  );

  "select3">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let command_feed = Fake_system.test_data "Command.xml" in
    let out = run_0install fake_system ["select"; command_feed] in
    assert_contains "Local.xml" out
  );

  "help3">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = run_0install fake_system ~exit:1 [] in
    assert (XString.starts_with out "Usage:");
    assert_contains "add-feed" out;
    assert_contains "--version" out;

    let out2 = run_0install fake_system ["--help"] in
    assert_str_equal out2 out;

    let out = run_0install fake_system ["--version"] in
    assert_contains "Thomas Leonard" out;

    Fake_system.assert_raises_safe "Unknown 0install sub-command" (lazy (
      run_0install fake_system ["foobar"] |> ignore
    ));
  );

  "run2">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let out = run_0install fake_system ~exit:1 ["run"] in
    assert (XString.starts_with out "Usage:");
    assert_contains "URI" out;

    let out = run_0install fake_system ["run"; "--dry-run"; Fake_system.test_data "runnable/Runnable.xml"; "--help"] in
    assert_contains "arg-for-runner" out;
    assert_contains "--help" out;
  );

  "update-alias">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    skip_if on_windows "Aliases don't work on Windows";
    let local_feed = Fake_system.test_data "Local.xml" in
    let bindir = fake_system#tmpdir +/ "bin" in
    fake_system#mkdir bindir 0o700;
    let launcher_script = bindir +/ "my-test-alias" in
    write_script fake_system launcher_script local_feed;

    Fake_system.assert_raises_safe "Bad interface name 'my-test-alias'.\n(hint: try 'alias:my-test-alias' instead)" (lazy (
      run_0install fake_system ["update"; "my-test-alias"] |> ignore
    ));
  );

  "man">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if on_windows "No man. No aliases";
    let out = run_0install fake_system ["man"; "--help"] in
    assert (XString.starts_with out "Usage:");

    (* Wrong number of args: pass-through *)
    check_man fake_system ["git"; "config"] ["man"; "git"; "config"];
    check_man fake_system [] ["man"];

    let local_feed = Fake_system.test_data "Local.xml" in
    let bindir = fake_system#tmpdir +/ "bin" in
    fake_system#mkdir bindir 0o700;
    let launcher_script = bindir +/ "my-test-alias" in
    write_script fake_system launcher_script local_feed;
    check_man fake_system ["my-test-alias"] ["man"; "tests/data/test-echo.1"];

    check_man fake_system ["__i_dont_exist"] ["man"; "__i_dont_exist"];
    check_man fake_system ["ls"] ["man"; "ls"];

    (* No man-page *)
    let binary_feed = Fake_system.test_data "Command.xml" |> U.realpath config.system in
    let launcher_script = bindir +/ "my-binary-alias" in
    write_script fake_system launcher_script binary_feed;

    let out = run_0install fake_system ~exit:1 ["man"; "my-binary-alias"] in
    assert_contains "No matching manpage was found for 'my-binary-alias'" out;
  );

  "alias">:: Fake_system.with_fake_config (fun (_config, fake_system) ->
    let tmpdir = fake_system#tmpdir in
    Unix.mkdir (tmpdir +/ "bin") 0o700;
    fake_system#putenv "PATH" ((tmpdir +/ "bin") ^ path_sep ^ U.getenv_ex fake_system "PATH");

    let local_feed = Fake_system.test_data "Local.xml" in
    let out = run_0install fake_system ~binary:"0alias" ["local-app"; local_feed] in
    assert_str_equal "(\"0alias\" is deprecated; using \"0install add\" instead)\n" out;
  );
]
