(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* These tests actually run a dummy web-server. *)

open Zeroinstall
open Zeroinstall.General
open Support
open Support.Common
open OUnit

module B = Support.Basedir
module Q = Support.Qdom
module U = Support.Utils
module F = Zeroinstall.Feed
module FC = Zeroinstall.Feed_cache

let assert_str_equal = Fake_system.assert_str_equal
let assert_contains = Fake_system.assert_contains
let expect = Fake_system.expect
let run_0install = Test_0install.run_0install

let binary iface = {Selections.iface; source = false}

let config_site = "0install.net"
let config_prog = "injector"

exception Open_gui

let parse_sels xml =
  try
    `String (0, xml)
    |> Xmlm.make_input
    |> Q.parse_input None
    |> Zeroinstall.Selections.create
  with Safe_exn.T _ as ex ->
    Safe_exn.reraise_with ex "... parsing %s" xml

let get_sel_path config sel =
  match Zeroinstall.Selections.get_source sel with
  | Zeroinstall.Selections.CacheSelection digests ->
      Zeroinstall.Stores.lookup_maybe config.system digests config.stores
  | _ -> assert_failure "Wrong type!"

let remove_cached config selections_path =
  let sels = Zeroinstall.Selections.load_selections config.system selections_path in
  let sel = Zeroinstall.Selections.(get_selected_ex {iface = "http://example.com:8000/Hello.xml"; source = false}) sels in
  let stored = expect @@ get_sel_path config sel in
  assert (XString.starts_with (Filename.basename stored) "sha1");
  U.rmtree ~even_if_locked:true config.system stored

let fake_gui =
  object (_ : #Zeroinstall.Ui.ui_handler)
    inherit Fake_system.null_ui
    method! run_solver = raise Open_gui
  end

let install_interceptor system checked_for_gui =
  Zeroinstall.Gui.register_plugin (fun _config ->
    let have_gui = system#getenv "DISPLAY" <> Some "" in
    checked_for_gui := true;
    if have_gui then (
      Some (fake_gui :> Zeroinstall.Ui.ui_handler)
    ) else (
      None
    )
  );
  Update.notify := (fun ~msg ~timeout:_ -> log_info "NOTIFY: 0install: %s" msg)

let do_recipe config fake_system server ?(expected=[[("HelloWorld.tar.bz2", `Serve)]]) name =
  let feed = Fake_system.test_data name in
  server#expect expected;
  let out = run_0install fake_system ["download"; feed; "--command="; "--xml"] in
  let sels = `String (0, out) |> Xmlm.make_input |> Q.parse_input None |> Zeroinstall.Selections.create in
  let sel = Zeroinstall.Selections.(get_selected_ex {iface = feed; source = false}) sels in
  get_sel_path config sel |> expect

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

  "auto-accept-key">:: Server.with_server (fun (_config, fake_system) server ->
    server#expect [[("Hello", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B", `AcceptKey)];
      [("HelloWorld.tgz", `Serve)]
    ];

    Fake_system.assert_raises_safe "Path '.*/HelloWorld/Missing' does not exist" (lazy (
      run_0install fake_system ~stdin:"" ["run"; "--main=Missing"; "-v"; "http://localhost:8000/Hello"] |> ignore
    ));
    Fake_system.fake_log#assert_contains "Automatically approving key for new feed \
      http://localhost:8000/Hello based on response from key info server: Approved for testing";
  );

  "reject-key">:: Server.with_server (fun (_config, fake_system) server ->
    server#expect [[("Hello", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B", `UnknownKey)];
    ];

    Fake_system.assert_raises_safe ".*Can't find all required implementations" (lazy (
      run_0install fake_system ~include_stderr:true ~stdin:"N\n" ["run"; "--main=Missing"; "-v"; "http://localhost:8000/Hello"] |> ignore
    ));
    Fake_system.fake_log#assert_contains "Quick solve failed; can't select without updating feeds";
    Fake_system.fake_log#assert_contains "Feed http://localhost:8000/Hello: Not signed with a trusted key";
  );

  "wrong-size">:: Server.with_server (fun (_config, fake_system) server ->
    server#expect [[("Hello-wrong-size", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B", `AcceptKey)];
      [("HelloWorld.tgz", `Serve)];
    ];

    Fake_system.assert_raises_safe "Downloaded archive has incorrect size" (lazy (
      run_0install fake_system ["run"; "--main=Missing"; "http://localhost:8000/Hello-wrong-size"; "Hello"] |> ignore
    ));
  );

  "wrong-digest">:: Server.with_server (fun (_config, fake_system) server ->
    server#expect [[("Hello.xml", `ServeFile "Hello-bad-digest.xml")];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B", `AcceptKey)];
      [("HelloWorld.tgz", `Serve)];
    ];

    Fake_system.assert_raises_safe "Incorrect manifest -- archive is corrupted" (lazy (
      run_0install fake_system ["run"; "--main=Missing"; "http://example.com:8000/Hello.xml"; "Hello"] |> ignore
    ));
  );

  "recipe">:: Server.with_server (fun (_config, fake_system) server ->
    server#expect [
      [("HelloWorld.tar.bz2", `Serve);
       ("/redirect/dummy_1-1_all.deb", `Redirect "/dummy_1-1_all.deb");
       ("dummy_1-1_all.deb", `Serve)];
    ];
    Fake_system.assert_raises_safe ".*HelloWorld/Missing' does not exist" (lazy (
      ignore @@ run_0install fake_system ["run"; Fake_system.test_data "Recipe.xml"]
    ))
  );

  "recipe-rename">:: Server.with_server (fun (config, fake_system) server ->
    let path = do_recipe config fake_system server "RecipeRename.xml" in
    assert (fake_system#file_exists (path +/ "HelloUniverse" +/ "minor"));
    assert (not (fake_system#file_exists (path +/ "HelloWorld")));
    assert (not (fake_system#file_exists (path +/ "HelloUniverse" +/ "main")))
  );

  "recipe-rename-to-new-dest">:: Server.with_server (fun (config, fake_system) server ->
    let path = do_recipe config fake_system server "RecipeRenameToNewDest.xml" in
    assert (fake_system#file_exists (path +/ "HelloWorld" +/ "bin" +/ "main"));
    assert (not (fake_system#file_exists (path +/ "HelloWorld" +/ "main")))
  );

  "recipe-remove-file" >:: Server.with_server (fun (config, fake_system) server ->
    let path = do_recipe config fake_system server "RecipeRemove.xml" in
    assert (fake_system#file_exists (path +/ "HelloWorld"));
    assert (not (fake_system#file_exists (path +/ "HelloWorld" +/ "main")))
  );

  "recipe-remove-dir" >:: Server.with_server (fun (config, fake_system) server ->
    let path = do_recipe config fake_system server "RecipeRemoveDir.xml" in
    assert (not (fake_system#file_exists (path +/ "HelloWorld")))
  );

  "recipe-extract-to-new-subdirectory" >:: Server.with_server (fun (config, fake_system) server ->
    let path = do_recipe config fake_system server "RecipeExtractToNewDest.xml" in
    assert (fake_system#file_exists (path +/ "src" +/ "HelloWorld" +/ "main"))
  );

  "recipe-single-file" >:: Server.with_server (fun (config, fake_system) server ->
    let path = do_recipe config fake_system server ~expected:[
      [("HelloWorldMain", `Serve)];
    ] "RecipeSingleFile.xml" in
    assert_str_equal "#!/bin/sh\necho Hello World\n" (U.read_file config.system (path +/ "bin" +/ "main"))
  );

  "recipe-extract-to-existing-subdirectory" >:: Server.with_server (fun (config, fake_system) server ->
    let path = do_recipe config fake_system server ~expected:[
      [("HelloWorld.tar.bz2", `Serve); ("HelloWorld.tar.bz2", `Serve)];
    ] "RecipeExtractToExistingDest.xml" in
    assert (fake_system#file_exists (path +/ "HelloWorld" +/ "main")); (* first archive's main *)
    assert (fake_system#file_exists (path +/ "HelloWorld" +/ "HelloWorld" +/ "main")) (* second archive, extracted to HelloWorld/ *)
  );

  "extract-to-new-subdirectory" >:: Server.with_server (fun (config, fake_system) server ->
    let path = do_recipe config fake_system server "HelloExtractToNewDest.xml" in
    assert (fake_system#file_exists (path +/ "src" +/ "HelloWorld" +/ "main"))
  );

  "download-file" >:: Server.with_server (fun (config, fake_system) server ->
    let path = do_recipe config fake_system server ~expected:[
      [("HelloWorldMain", `Serve)];
    ] "HelloSingleFile.xml" in
    assert_str_equal "#!/bin/sh\necho Hello World\n" (U.read_file config.system (path +/ "main"))
  );

  "symlink-attack" >:: Server.with_server (fun (config, fake_system) server ->
    Fake_system.assert_raises_safe "Attempt to unpack dir over non-directory 'HelloWorld'" (lazy (
      ignore @@ do_recipe config fake_system server ~expected:[
        [("HelloWorld.tar.bz2", `Serve); ("HelloSym.tgz", `Serve)];
      ] "RecipeSymlink.xml"
    ));
  );

  "recipe-failure" >:: Server.with_server (fun (config, fake_system) server ->
    Fake_system.assert_raises_safe "Error downloading 'http://localhost:8000/redirect/dummy_1-1_all.deb': The requested URL returned error: 404" (lazy (
      ignore @@ do_recipe config fake_system server ~expected:[
        [("HelloWorld.tar.bz2", `Serve); ("/redirect/dummy_1-1_all.deb", `Give404)];
      ] "Recipe.xml"
    ));
  );

  "autopackage" >:: Server.with_server (fun (config, fake_system) server ->
    let path = do_recipe config fake_system server ~expected:[
        [("HelloWorld.autopackage", `Serve)];
      ] "Autopackage.xml" in
    assert_str_equal "#!/bin/sh\necho Hello World\n" (U.read_file config.system (path +/ "HelloWorld" +/ "main"))
  );

  "dry-run">:: Server.with_server (fun (_config, fake_system) server ->
    server#expect [[("Hello", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B", `AcceptKey)];
      [("HelloWorld.tgz", `Serve)]
    ];
    let out = run_0install fake_system ["run"; "--dry-run"; "http://localhost:8000/Hello"; "Hello"] in
    let expected =
      "\\[dry-run] downloading feed from http://localhost:8000/Hello\n\
       \\[dry-run] asking http://localhost:3333/key-info about key DE937DD411906ACF7C263B396FCF121BE2390E0B\n\
       \\[dry-run] would trust key DE937DD411906ACF7C263B396FCF121BE2390E0B for localhost:8000\n\
       \\[dry-run] would update trust database .*/config/injector/trustdb.xml\n\
       \\[dry-run] would cache feed http://localhost:8000/Hello as .*/cache/interfaces/http%3a%2f%2flocalhost%3a8000%2fHello\n\
       \\[dry-run] downloading http://localhost:8000/HelloWorld.tgz\n\
       \\[dry-run] would store implementation as .*/cache/implementations/sha1=3ce644dc725f1d21cfcf02562c76f375944b266a\n\
       \\[dry-run] would execute: .*HelloWorld/main Hello\n" in
    if not (Str.string_match (Str.regexp expected) out 0) then
      Safe_exn.failf "No match. Got:\n%s" out;
  );

  "import">:: Server.with_server (fun (config, fake_system) server ->
    Fake_system.assert_raises_safe "File 'NO-SUCH-FILE' does not exist" (lazy (
      run_0install fake_system ["import"; "-v"; "NO-SUCH-FILE"] |> ignore
    ));

    assert_equal None @@ FC.get_cached_feed config (`Remote_feed "http://localhost:8000/Hello");

    server#expect [
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B", `UnknownKey)];
    ];

    let trust_db = new Zeroinstall.Trust.trust_db config in

    let domain = "localhost:8000" in
    assert (not (trust_db#is_trusted ~domain "DE937DD411906ACF7C263B396FCF121BE2390E0B"));
    let out = run_0install fake_system ~stdin:"Y\n" ~include_stderr:true ["import"; "-v"; Fake_system.test_data "Hello"] in
    assert_contains "Warning: Nothing known about this key!" out;
    Fake_system.fake_log#assert_contains "Trusting DE937DD411906ACF7C263B396FCF121BE2390E0B for localhost:8000";
    assert (trust_db#is_trusted ~domain "DE937DD411906ACF7C263B396FCF121BE2390E0B");

    (* Check we imported the interface after trusting the key *)
    let hello = FC.get_cached_feed config (`Remote_feed "http://localhost:8000/Hello") |> Fake_system.expect in
    assert_equal 1 @@ XString.Map.cardinal hello.F.implementations;

    (* Shouldn't need to prompt the second time *)
    let out = run_0install fake_system ~stdin:"" ["import"; Fake_system.test_data "Hello"] in
    Fake_system.assert_str_equal "" out;
  );

  "distro">:: Server.with_server (fun (config, fake_system) server ->
    let packagekit = lazy (Fake_distro.fake_packagekit (`Unavailable "Use apt-cache")) in
    let native_url = "http://example.com:8000/Native.xml" in
    fake_system#set_spawn_handler (Some Fake_system.real_spawn_handler);

    (* Initially, we don't have the feed at all... *)
    assert_equal None @@ FC.get_cached_feed config (`Remote_feed native_url);

    server#expect [
      [("Native.xml", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B", `AcceptKey)];   (* ?? *)
    ];
    Fake_system.assert_raises_safe "Can't find all required implementations" (lazy (
      run_0install fake_system ["download"; native_url] |> ignore
    ));

    let feed = Fake_system.expect @@ FC.get_cached_feed config (`Remote_feed native_url) in
    assert_equal 0 @@ XString.Map.cardinal feed.F.implementations;

    let dpkgdir = Fake_system.test_data "dpkg" in
    let old_path = Unix.getenv "PATH" in
    Unix.putenv "PATH" (dpkgdir ^ ":" ^ old_path);
    fake_system#putenv "PATH" (dpkgdir ^ ":" ^ old_path);
    let deb = Zeroinstall.Distro_impls.Debian.debian_distribution ~status_file:(dpkgdir +/ "status") ~packagekit config in

    Fake_system.fake_log#reset;
    Lwt_main.run @@ deb#check_for_candidates ~ui:Fake_system.null_ui feed;
    begin match Test_distro.to_impl_list @@ deb#get_impls_for_feed ~problem:failwith feed with
    | [_impl1; _impl2] -> ()
    | items -> Safe_exn.failf "Got %d!" (List.length items) end;

    Unix.putenv "PATH" old_path;
  );

  "mirrors">:: Server.with_server (fun (config, fake_system) server ->
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
      [("/0mirror/archive/http:%23%23example.com:8000%23HelloWorld.tgz", `ServeFile "HelloWorld.tgz")];
    ];
    let out = Fake_system.collect_logging (fun () ->
      run_0install fake_system ["download"; "http://example.com:8000/Hello.xml"; "--xml"]
    ) in
    Fake_system.fake_log#assert_contains {|Primary download failed; trying mirror URL 'http://roscidus.com/0mirror/archive/http\(%3A\|:\)%23%23example\(.\|%2E\)com\(%3A\|:\)8000%23HelloWorld\(.\|%2E\)tgz'|};
    let sels = parse_sels out in
    let sel = Zeroinstall.Selections.get_selected_ex (binary "http://example.com:8000/Hello.xml") sels in
    assert (fake_system#file_exists (expect (get_sel_path config sel) +/ "HelloWorld" +/ "main"))
  );

  "impl-mirror">:: Server.with_server (fun (config, fake_system) server ->
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
      [("/0mirror/archive/http:%23%23example.com:8000%23HelloWorld.tgz", `Give404)];
      [("/0mirror/feeds/http/example.com:8000/Hello.xml/impl/sha1=3ce644dc725f1d21cfcf02562c76f375944b266a",
          `ServeFile "HelloWorld.tar.bz2")];
    ];
    let out = Fake_system.collect_logging (fun () ->
      run_0install fake_system ["download"; "http://example.com:8000/Hello.xml"; "--xml"]
    ) in
    Fake_system.fake_log#assert_contains ".* 404.*: trying implementation mirror at http://roscidus.com/0mirror";
    let sels = parse_sels out in
    let sel = Zeroinstall.Selections.get_selected_ex (binary "http://example.com:8000/Hello.xml") sels in
    begin match Zeroinstall.Selections.get_source sel with
    | Zeroinstall.Selections.CacheSelection digests ->
        let path = Zeroinstall.Stores.lookup_any config.system digests config.stores in
        assert (fake_system#file_exists (path +/ "HelloWorld" +/ "main"))
    | _ -> assert false end;
  );

  "impl-mirror-fails">:: Server.with_server (fun (config, fake_system) server ->
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
      [("/0mirror/archive/http:%23%23example.com:8000%23HelloWorld.tgz", `Give404)];
      [("/0mirror/feeds/http/example.com:8000/Hello.xml/impl/sha1=3ce644dc725f1d21cfcf02562c76f375944b266a", `Give404)];
    ];

    Fake_system.assert_raises_safe "Error downloading 'http://example.com:8000/HelloWorld.tgz': \
                                    The requested URL returned error: 404" (lazy (
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
      {|.*http://roscidus.com/0mirror/archive/http\(:\|%3A\)%23%23example\(.\|%2E\)com\(:\|%3A\)8000%23HelloWorld\(.\|%2E\)tgz|};
      (* Mirror of implementation: *)
      ".*http://roscidus.com/0mirror/feeds/http/example.com:8000/Hello.xml/impl/sha1=3ce644dc725f1d21cfcf02562c76f375944b266a"
    ] |> List.iter Fake_system.fake_log#assert_contains
  );

  "local-feed-mirror">:: Server.with_server (fun (config, fake_system) server ->
    (* This is like testImplMirror, except we have a local feed. *)

    let path =
      Fake_system.collect_logging (fun () ->
        do_recipe config fake_system server ~expected:[
          [("/HelloWorld.tgz", `Give404)];
          [("/0mirror/archive/http:%23%23example.com:8000%23HelloWorld.tgz", `ServeFile "HelloWorld.tgz")];
        ] "Hello.xml"
      ) in

    Fake_system.fake_log#assert_contains @@
    {|Primary download failed; trying mirror URL |} ^
    {|'http://roscidus.com/0mirror/archive/http\(:\|%3A\)%23%23example\(.\|%2E\)com\(:\|%3A\)8000%23HelloWorld\(.\|%2E\)tgz'...|};

    assert (fake_system#file_exists (path +/ "HelloWorld" +/ "main"))
  );

  "selections">:: Server.with_server (fun (config, fake_system) server ->
    let sels = Zeroinstall.Selections.load_selections config.system (Fake_system.test_data "selections.xml") in

    server#expect [
      [("Hello.xml", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("/key-info/key/DE937DD411906ACF7C263B396FCF121BE2390E0B", `AcceptKey)];
      [("HelloWorld.tgz", `Serve)];
    ];

    let sel = Zeroinstall.Selections.get_selected_ex (binary "http://example.com:8000/Hello.xml") sels in
    assert_equal None @@ get_sel_path config sel;

    let out = run_0install fake_system ["download"; Fake_system.test_data "selections.xml"] in
    Fake_system.assert_str_equal "" out;
    Fake_system.fake_log#assert_contains "Automatically approving key for new feed";

    assert (fake_system#file_exists @@ expect (get_sel_path config sel) +/ "HelloWorld" +/ "main");
    assert_equal [] @@ Zeroinstall.Driver.get_unavailable_selections config sels
  );

  "background-app">:: Server.with_server (fun (config, fake_system) server ->
    let system = config.system in
    let home = U.getenv_ex system "HOME" in
    system#mkdir (home +/ "bin") 0o700;
    fake_system#allow_spawn_detach true;

    let trust_db = new Zeroinstall.Trust.trust_db config in
    let domain = "example.com:8000" in
    trust_db#trust_key ~domain "DE937DD411906ACF7C263B396FCF121BE2390E0B";

    (* Create an app, downloading a version of Hello *)
    server#expect [
      [("Hello.xml", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("HelloWorld.tgz", `Serve)];
    ];
    let out = run_0install fake_system ["add"; "test-app"; "http://example.com:8000/Hello.xml"] in
    assert_str_equal "" out;

    let app = expect @@ Zeroinstall.Apps.lookup_app config "test-app" in
    let timestamp = app +/ "last-checked" in
    let last_check_attempt = app +/ "last-check-attempt" in
    let selections_path = app +/ "selections.xml" in

    let reset_timestamps () =
      system#set_mtime timestamp 1.0;		(* 1970 *)
      system#set_mtime selections_path 1.0;
      if system#file_exists last_check_attempt then
        system#unlink last_check_attempt in

    let get_mtime path =
      match system#lstat path with
      | Some info -> info.Unix.st_mtime
      | None -> Safe_exn.failf "Missing '%s'" path in

    (* Not time for a background update yet *)
    config.freshness <- Some 1000.0;
    assert_str_equal "" @@ run_0install fake_system ["download"; "test-app"];

    let checked_for_gui = ref false in
    install_interceptor config.system checked_for_gui;
    reset_timestamps ();
    server#expect [
      [("Hello.xml", `Serve)];
    ];

    assert_str_equal "" @@ run_0install fake_system ["download"; "test-app"];
    Fake_system.fake_log#assert_contains "Background update: no updates found for test-app";
    assert (get_mtime timestamp <> 1.0);
    assert_equal 1.0 (get_mtime selections_path);

    (* Change the selections *)
    let () =
      let old_selections = U.read_file system selections_path in
      let new_selections = Str.global_replace (Str.regexp_string "Hello") "Goodbye" old_selections in
      selections_path |> system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
        output_string ch new_selections
      ) in

    (* Trigger another background update - metadata changes found *)
    reset_timestamps ();
    server#expect [
      [("Hello.xml", `Serve)];
    ];

    ignore @@ run_0install fake_system ["download"; "test-app"];
    Fake_system.fake_log#assert_contains "Quick solve succeeded; saving new selections";

    assert (1.0 <> get_mtime timestamp);
    assert (1.0 <> get_mtime selections_path);

    (* Trigger another background update - GUI needed now *)

    (* Delete cached implementation so we need to download it again *)
    remove_cached config selections_path;

    (* Replace with a valid local feed so we don't have to download immediately *)
    let replace_with_local () =
      selections_path |> system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
        output_string ch "<?xml version='1.0' ?>\n\
          <selections command='run' interface='http://example.com:8000/Hello.xml'\n\
                      xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>\n\
            <selection id='.' local-path='.' interface='http://example.com:8000/Hello.xml' version='0.1'>\n\
              <command name='run' path='foo'/>\n\
            </selection>\n\
          </selections>"
      ) in

    (* Background update using the GUI *)
    replace_with_local ();
    fake_system#putenv "DISPLAY" "dummy";
    reset_timestamps ();
    server#expect [
      [("Hello.xml", `Serve)];
    ];
    checked_for_gui := false;
    Fake_system.collect_logging (fun () ->
      assert_str_equal "" @@ run_0install fake_system ["download"; "test-app"];
    );
    Fake_system.fake_log#assert_contains "Background update: trying to use GUI to update test-app";
    assert !checked_for_gui;

    (* Background update without GUI *)
    checked_for_gui := false;
    replace_with_local ();
    fake_system#putenv "DISPLAY" "";
    reset_timestamps ();
    server#expect [
      [("Hello.xml", `Serve)];
      [("HelloWorld.tgz", `Serve)];
    ];
    assert_str_equal "" @@ run_0install fake_system ["download"; "test-app"];
    Fake_system.fake_log#assert_contains "Background update: GUI unavailable; downloading with no UI";
    assert (not !checked_for_gui);

    assert (1.0 <> get_mtime timestamp);
    assert (1.0 <> get_mtime selections_path);

    let sels = Zeroinstall.Selections.load_selections system selections_path in
    let sel = Zeroinstall.Selections.get_selected_ex (binary "http://example.com:8000/Hello.xml") sels in
    assert_equal "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" (Element.id sel);

    (* Untrust the key - we'll need to use the GUI to confirm it again *)
    trust_db#untrust_key ~domain "DE937DD411906ACF7C263B396FCF121BE2390E0B";
    fake_system#putenv "DISPLAY" "";
    replace_with_local ();
    reset_timestamps ();
    server#expect [
      [("Hello.xml", `Serve)];
      [("DE937DD411906ACF7C263B396FCF121BE2390E0B", `UnknownKey)];
    ];
    Fake_system.collect_logging (fun () ->
      assert_str_equal "" @@ run_0install fake_system ["download"; "test-app"];
    );
    Fake_system.fake_log#assert_contains ".*need to switch to GUI to confirm keys";
    Fake_system.fake_log#assert_contains "Can't update 0install app 'test-app' without user intervention (run '0install update test-app' to fix)";

    (* Update not triggered because of last-check-attempt *)
    system#set_mtime timestamp 1.0;		(* 1970 *)
    system#set_mtime selections_path 1.0;
    assert_str_equal "" @@ run_0install fake_system ["download"; "test-app"];
    Fake_system.fake_log#assert_contains "Tried to check within last hour; not trying again now"
  );

  "background-unsolvable">:: Server.with_server (fun (config, fake_system) server ->
    fake_system#allow_spawn_detach true;
    fake_system#set_spawn_handler (Some Fake_system.real_spawn_handler);  (* For "ports -v" *)
    let trust_db = new Zeroinstall.Trust.trust_db config in
    let system = config.system in
    let home = U.getenv_ex system "HOME" in
    system#mkdir (home +/ "bin") 0o700;
    let domain = "example.com:8000" in
    trust_db#trust_key ~domain "DE937DD411906ACF7C263B396FCF121BE2390E0B";

    let checked_for_gui = ref false in
    install_interceptor config.system checked_for_gui;

    (* Create an app, downloading a version of Hello *)
    server#expect [
      [("Hello.xml", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("HelloWorld.tgz", `Serve)];
    ];
    Fake_system.collect_logging (fun () ->
      assert_str_equal "" @@ run_0install fake_system ["add"; "test-app"; "http://example.com:8000/Hello.xml"]
    );

    let app = expect @@ Zeroinstall.Apps.lookup_app config "test-app" in
    let selections_path = app +/ "selections.xml" in

    (* Delete cached implementation so we need to download it again *)
    remove_cached config selections_path;

    (* Replace the selection with a bogus and unusable <package-implementation> *)
    let sels = Q.parse_file system selections_path in
    let sels = {sels with
      Q.child_nodes =
        begin match sels.Q.child_nodes with
        | [sel] -> [{sel with
            Q.attrs = sel.Q.attrs
            |> Q.AttrMap.add_no_ns "id" "package:dummy:badpackage"
            |> Q.AttrMap.add_no_ns "from-feed" "distribution:http://example.com:8000/Hello.xml"
            |> Q.AttrMap.add_no_ns "package" "badpackage"
            |> Q.AttrMap.add_no_ns "main" "/i/dont/exist"
        }]
        | _ -> assert false end;
    } in
    selections_path |> system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
      Q.to_utf8 sels |> output_string ch
    );

    (* Not time for a background update yet, but the missing binary should trigger
     * an update anyway. *)
    config.freshness <- None;

    fake_system#putenv "DISPLAY" "dummy";
    begin try assert_str_equal "" @@ run_0install fake_system ["download"; "test-app"];
    with Open_gui -> () end;
    Fake_system.fake_log#assert_contains ".*get new selections; current ones are not usable";

    (* Check we can also work without the GUI... *)
    fake_system#putenv "DISPLAY" "";
    server#expect [
      [("Hello.xml", `Serve)];
      [("HelloWorld.tgz", `Serve)];
    ];
    assert_str_equal "" @@ run_0install fake_system ["download"; "test-app"];
    Fake_system.fake_log#assert_contains ".*get new selections; current ones are not usable";

    let timestamp = app +/ "last-checked" in
    let last_check_attempt = app +/ "last-check-attempt" in

    system#set_mtime timestamp 1.0;		(* 1970 *)
    system#set_mtime selections_path 1.0;
    if system#file_exists last_check_attempt then
      system#unlink last_check_attempt;

    (* Now trigger a background update which discovers that no solution is possible *)
    server#expect [
      [("Hello.xml", `ServeFile "Hello-impossible.xml")];
    ];
    Fake_system.collect_logging (fun () ->
      assert_str_equal "" @@ run_0install fake_system ["download"; "test-app"]
    );
    Fake_system.fake_log#assert_contains
      "NOTIFY: 0install: Can't update 0install app 'test-app' (run '0install update test-app' to fix)";

    assert_str_equal "" @@ run_0install fake_system ["destroy"; "test-app"];
  );

  "add-impossible">:: Server.with_server (fun (_config, fake_system) server ->
    server#expect [
      [("Hello.xml", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("DE937DD411906ACF7C263B396FCF121BE2390E0B", `AcceptKey)];
    ];
    Fake_system.assert_raises_safe "\\(.\\|\n\\)*We want source and this is a binary" (lazy (
      ignore @@ run_0install fake_system ["add"; "--source"; "test-app"; "http://example.com:8000/Hello.xml"]
    ));
  );

  "replay">:: Server.with_server (fun (config, fake_system) server ->
    let iface = "http://example.com:8000/Hello.xml" in
    let system = config.system in
    let cached = FC.get_save_cache_path config (`Remote_feed iface) in
    U.copy_file system (Fake_system.test_data "Hello-new.xml") cached 0o644;

    let trust_db = new Zeroinstall.Trust.trust_db config in
    let domain = "example.com:8000" in
    trust_db#trust_key ~domain "DE937DD411906ACF7C263B396FCF121BE2390E0B";

    server#expect [
      [("/Hello.xml", `Give404)];
      [("latest.xml", `ServeFile "Hello.xml")];
      [("/0mirror/keys/6FCF121BE2390E0B.gpg", `Serve)];
    ];

    (* Update from mirror (should ignore out-of-date timestamp) *)
    Fake_system.collect_logging (fun () ->
      let out = run_0install fake_system ["select"; "--refresh"; iface] in
      assert_contains "Version: 1" out
    );
    Fake_system.fake_log#assert_contains "Version from mirror is older than cached version; ignoring it";

    server#expect [
      [("Hello.xml", `Serve)];
    ];

    (* Update from upstream (should report an error) *)
    Fake_system.collect_logging (fun () ->
      let out = run_0install fake_system ["select"; "--refresh"; iface] in
      assert_contains "Version: 1" out;
    );
    Fake_system.fake_log#assert_contains ".* New feed's modification time is before old version";

    (* Must finish with the newest version *)
    let actual = U.read_file system cached in
    let expected = U.read_file system (Fake_system.test_data "Hello-new.xml") in
    assert_equal expected actual
  );

  "download-icon-fails">:: Server.with_server (fun (config, _fake_system) server ->
    server#expect [
      [("/missing.png", `Give404)];
    ];
    let tools = Fake_system.make_tools config in
    let feed_provider = new Zeroinstall.Feed_provider_impl.feed_provider config tools#distro in
    let iface = Fake_system.test_data "Binary.xml" in
    Fake_system.assert_raises_safe "Error downloading 'http://localhost/missing.png': \
                                    The requested URL returned error: 404" (lazy (
      Lwt_main.run @@ Zeroinstall.Gui.download_icon (tools#make_fetcher tools#ui#watcher) feed_provider (`Local_feed iface);
    ));
  );

  "search">:: Server.with_server (fun (_config, fake_system) server ->
    server#expect [
      [("/0mirror/search/?q=firefox", `ServeFile "search-firefox.xml")];
    ];

    let out = run_0install ~exit:1 fake_system ["search"] in
    assert_contains "Usage:" out;
    assert_contains "QUERY" out;

    let out = run_0install fake_system ["search"; "firefox"] in
    assert_contains "Firefox - Webbrowser" out
  );

  "select">:: Server.with_server ~portable_base:false (fun (config, fake_system) server ->
    server#expect [
      [("Hello.xml", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("DE937DD411906ACF7C263B396FCF121BE2390E0B", `AcceptKey)];
    ];
    let out = run_0install fake_system ["select"; Fake_system.test_data "selections.xml"] in
    assert_contains "Version: 1\n" out;
    assert_contains "(not cached)" out;

    (* Check background select - update metadata only *)
    let url = "http://example.com:8000/Hello.xml" in
    F.save_feed_overrides config (`Remote_feed url) F.({last_checked = None; user_stability = XString.Map.empty});
    let rel_path = config_site +/ config_prog +/ "last-check-attempt" +/ Zeroinstall.Escape.pretty url in
    let basedirs = Support.Basedir.get_default_config config.system in
    let last_check_attempt = B.load_first config.system rel_path basedirs.B.cache |> expect in
    fake_system#unlink last_check_attempt;

    fake_system#allow_spawn_detach true;

    server#expect [
      [("Hello.xml", `Serve)];
    ];
    let out = run_0install fake_system ["select"; Fake_system.test_data "selections.xml"] in
    assert_contains "Version: 1\n" out;
    assert_contains "(not cached)" out;
  );

  "short-redirect">:: Server.with_server (fun _ server ->
    server#expect [
      ["Link", `Redirect "/Short"];
      ["Short", `Serve];
    ];
    let pool = Downloader.make_pool ~max_downloads_per_site:1 in
    let dl = pool#with_monitor ignore in
    Lwt_main.run begin
      let switch = Lwt_switch.create () in
      Downloader.download dl ~switch ~size:2L "http://example.com:8000/Link" >|= function
      | `Tmpfile _ -> ()
      | _ -> OUnit.assert_failure "Download failed!"
    end;
    pool#release
  );

  "slave-2.6">:: Server.with_server ~portable_base:false (fun (config, _fake_system) server ->
    server#expect [
      [("Hello.xml", `Serve)];
      [("6FCF121BE2390E0B.gpg", `Serve)];
      [("DE937DD411906ACF7C263B396FCF121BE2390E0B", `AcceptKey)];
    ];
    let tools = Fake_system.make_tools config in
    let from_peer, to_slave = Lwt_io.pipe () in
    let from_slave, to_peer = Lwt_io.pipe () in
    let requested_api_version = Version.parse "2.6" in
    let slave = Slave.run_slave config tools ~from_peer ~to_peer ~requested_api_version in
    Fake_system.monitor slave;
    let callback _conn (x, _) = failwith x in
    Lwt_main.run begin
      Json_connection.client ~from_peer:from_slave ~to_peer:to_slave callback
      >>= fun (client, client_thread, version) ->
      Fake_system.monitor client_thread;
      OUnit.assert_equal "2.6" (Version.to_string version);
      Json_connection.invoke client "select" [
        `Assoc [
          "interface", `String "http://example.com:8000/Hello.xml";
        ];
        `Bool false
      ] >>= begin function
      | `WithXML (`List [`String "ok"], xml) -> Lwt.return xml
      | x -> Safe_exn.failf "Bad reply %a" Json_connection.pp_opt_xml x
      end >>= fun xml ->
      let sels = Selections.create xml in
      let impl = Selections.(get_selected (root_role sels) sels) |> expect in
      Selections.get_id impl |> assert_equal { Feed_url.
        feed = `Remote_feed "http://example.com:8000/Hello.xml";
        id = "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a"
      };
      Lwt.cancel slave;
      Lwt.cancel client_thread;
      Lwt.return ()
    end
  );
]
