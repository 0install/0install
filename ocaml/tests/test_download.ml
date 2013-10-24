(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* These tests actually run a dummy web-server. *)

open Zeroinstall.General
open Support.Common
open OUnit

module Q = Support.Qdom
module F = Zeroinstall.Feed
module FC = Zeroinstall.Feed_cache

let assert_contains = Fake_system.assert_contains

let run_0install ?stdin ?(include_stderr=false) fake_system ?(exit=0) args =
  let run = lazy (
    Fake_system.fake_log#reset;
    fake_system#set_argv @@ Array.of_list (Test_0install.test_0install :: args);
    Fake_system.capture_stdout ~include_stderr (fun () ->
      try Main.main (fake_system : Fake_system.fake_system :> system); assert (exit = 0)
      with System_exit n -> assert_equal ~msg:"exit code" n exit
    )
  ) in
  match stdin with
  | None -> Lazy.force run
  | Some stdin -> fake_system#with_stdin stdin run

let parse_sels xml =
  try
    let sels = `String (0, xml) |> Xmlm.make_input |> Q.parse_input None |> Zeroinstall.Selections.to_latest_format in
    Zeroinstall.Selections.make_selection_map sels
  with Safe_exception _ as ex ->
    reraise_with_context ex "... parsing %s" xml

let suite = "download">::: [
  "accept-key">:: Server.with_server (fun (_config, fake_system) server ->
    server#expect [[("Hello", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B", `UnknownKey)];
      [("HelloWorld.tgz", `Serve)]
    ];

    Fake_system.assert_raises_safe "Path '.*/HelloWorld/Missing' does not exist" (lazy (
      run_0install fake_system ~include_stderr:true ~stdin:"Y\n" ["run"; "--main=Missing"; "-v"; "http://localhost:8000/Hello"] |> ignore
    ));
    Fake_system.fake_log#assert_contains "Trusting DE937DD411906ACF7C263B396FCF121BE2390E0B for localhost:8000";
  );

  "import">:: Server.with_server (fun (config, fake_system) server ->
    Fake_system.assert_raises_safe "File 'NO-SUCH-FILE' does not exist" (lazy (
      run_0install fake_system ["import"; "-v"; "NO-SUCH-FILE"] |> ignore
    ));

    assert_equal None @@ FC.get_cached_feed config (`remote_feed "http://localhost:8000/Hello");

    server#expect [
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B", `UnknownKey)];
    ];

    let trust_db = new Zeroinstall.Trust.trust_db config in

    let domain = "localhost:8000" in
    assert (not (trust_db#is_trusted ~domain "DE937DD411906ACF7C263B396FCF121BE2390E0B"));
    let out = run_0install fake_system ~stdin:"Y\n" ~include_stderr:true ["import"; "-v"; Test_0install.feed_dir +/ "Hello"] in
    assert_contains "Warning: Nothing known about this key!" out;
    Fake_system.fake_log#assert_contains "Trusting DE937DD411906ACF7C263B396FCF121BE2390E0B for localhost:8000";
    assert (trust_db#is_trusted ~domain "DE937DD411906ACF7C263B396FCF121BE2390E0B");

    (* Check we imported the interface after trusting the key *)
    let hello = FC.get_cached_feed config (`remote_feed "http://localhost:8000/Hello") |> Fake_system.expect in
    assert_equal 1 @@ StringMap.cardinal hello.F.implementations;

    (* Shouldn't need to prompt the second time *)
    let out = run_0install fake_system ~stdin:"" ["import"; Test_0install.feed_dir +/ "Hello"] in
    Fake_system.assert_str_equal "" out;
  );

  "distro">:: Server.with_server (fun (config, fake_system) server ->
    let native_url = "http://example.com:8000/Native.xml" in

    (* Initially, we don't have the feed at all... *)
    assert_equal None @@ FC.get_cached_feed config (`remote_feed native_url);

    server#expect [
      [("Native.xml", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B", `AcceptKey)];   (* ?? *)
    ];
    Fake_system.assert_raises_safe "Can't find all required implementations" (lazy (
      run_0install fake_system ["download"; native_url] |> ignore
    ));

    let feed = Fake_system.expect @@ FC.get_cached_feed config (`remote_feed native_url) in
    assert_equal 0 @@ StringMap.cardinal feed.F.implementations;

    let dpkgdir = Test_0install.feed_dir +/ "dpkg" in
    let old_path = Unix.getenv "PATH" in
    Unix.putenv "PATH" (dpkgdir ^ ":" ^ old_path);
    let slave = Test_distro.get_test_slave config "DebianDistribution" [`String (dpkgdir +/ "status")] in
    let deb = new Zeroinstall.Distro.Debian.debian_distribution config slave in

    Lwt_main.run @@ deb#check_for_candidates feed;
    begin match Zeroinstall.Distro.get_package_impls deb feed with
    | Some [_impl1; _impl2] -> ()
    | _ -> assert false end;

    Unix.putenv "PATH" old_path;
  );

  "mirrors">:: Server.with_server (fun (config, fake_system) server ->
    Support.Logging.threshold := Support.Logging.Info;

    let config = {config with
      auto_approve_keys = false;
      mirror = Some "http://example.com:8000/0mirror";
    } in
    Zeroinstall.Config.save_config config;

    let trust_db = new Zeroinstall.Trust.trust_db config in
    let domain = "example.com:8000" in
    trust_db#trust_key "DE937DD411906ACF7C263B396FCF121BE2390E0B" ~domain;

    server#expect [
      [("/Hello.xml", `Give404)];
      [("/0mirror/feeds/http/example.com:8000/Hello.xml/latest.xml", `ServeFile "Hello.xml")];
      [("/0mirror/keys/6FCF121BE2390E0B.gpg", `Serve)];
      [("/HelloWorld.tgz", `Give404)];
      [("/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz", `ServeFile "HelloWorld.tgz")];
    ];
    let out = Fake_system.collect_logging (fun () ->
      run_0install fake_system ["download"; "http://example.com:8000/Hello.xml"; "--xml"]
    ) in
    Fake_system.fake_log#assert_contains "Primary download failed; trying mirror URL 'http://roscidus.com/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz'";
    let sels = parse_sels out in
    let sel = StringMap.find "http://example.com:8000/Hello.xml" sels in
    begin match Zeroinstall.Selections.make_selection sel with
    | Zeroinstall.Selections.CacheSelection digests ->
        let path = Zeroinstall.Stores.lookup_any config.system digests config.stores in
        assert (fake_system#file_exists (path +/ "HelloWorld" +/ "main"))
    | _ -> assert false end;
  );

  "impl-mirror">:: Server.with_server (fun (config, fake_system) server ->
    Support.Logging.threshold := Support.Logging.Info;

    let config = {config with
      auto_approve_keys = false;
      mirror = Some "http://example.com:8000/0mirror";
    } in
    Zeroinstall.Config.save_config config;

    let trust_db = new Zeroinstall.Trust.trust_db config in
    let domain = "example.com:8000" in
    trust_db#trust_key "DE937DD411906ACF7C263B396FCF121BE2390E0B" ~domain;

    server#expect [
      [("/Hello.xml", `Serve)];
      [("/6FCF121BE2390E0B.gpg", `Serve)];
      [("/HelloWorld.tgz", `Give404)];
      [("/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz", `Give404)];
      [("/0mirror/feeds/http/example.com:8000/Hello.xml/impl/sha1=3ce644dc725f1d21cfcf02562c76f375944b266a",
          `ServeFile "HelloWorld.tar.bz2")];
    ];
    let out = Fake_system.collect_logging (fun () ->
      run_0install fake_system ["download"; "http://example.com:8000/Hello.xml"; "--xml"]
    ) in
    Fake_system.fake_log#assert_contains ".*Missing: HelloWorld.tgz: trying implementation mirror at http://roscidus.com/0mirror";
    let sels = parse_sels out in
    let sel = StringMap.find "http://example.com:8000/Hello.xml" sels in
    begin match Zeroinstall.Selections.make_selection sel with
    | Zeroinstall.Selections.CacheSelection digests ->
        let path = Zeroinstall.Stores.lookup_any config.system digests config.stores in
        assert (fake_system#file_exists (path +/ "HelloWorld" +/ "main"))
    | _ -> assert false end;
  );

  "impl-mirror-fails">:: Server.with_server (fun (config, fake_system) server ->
    Support.Logging.threshold := Support.Logging.Info;

    let config = {config with
      auto_approve_keys = false;
      mirror = Some "http://example.com:8000/0mirror";
    } in
    Zeroinstall.Config.save_config config;

    let trust_db = new Zeroinstall.Trust.trust_db config in
    let domain = "example.com:8000" in
    trust_db#trust_key "DE937DD411906ACF7C263B396FCF121BE2390E0B" ~domain;

    server#expect [
      [("/Hello.xml", `Serve)];
      [("/6FCF121BE2390E0B.gpg", `Serve)];
      [("/HelloWorld.tgz", `Give404)];
      [("/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz", `Give404)];
      [("/0mirror/feeds/http/example.com:8000/Hello.xml/impl/sha1=3ce644dc725f1d21cfcf02562c76f375944b266a", `Give404)];
    ];

    Fake_system.assert_raises_safe "Error downloading 'http://example.com:8000/HelloWorld.tgz': \
                                    The requested URL returned error: 404 Missing: HelloWorld.tgz" (lazy (
      Fake_system.collect_logging (fun () ->
        run_0install fake_system ["download"; "http://example.com:8000/Hello.xml"; "--xml"] |> ignore
      )
    ));

    [
      ".*http://example.com:8000/Hello.xml";
      ".*http://example.com:8000/6FCF121BE2390E0B.gpg";
      (* The original archive: *)
      ".*http://example.com:8000/HelloWorld.tgz";
      (* Mirror of original archive: *)
      ".*http://roscidus.com/0mirror/archive/http%3A%23%23example.com%3A8000%23HelloWorld.tgz";
      (* Mirror of implementation: *)
      ".*http://roscidus.com/0mirror/feeds/http/example.com:8000/Hello.xml/impl/sha1=3ce644dc725f1d21cfcf02562c76f375944b266a"
    ] |> List.iter Fake_system.fake_log#assert_contains
  );
]
