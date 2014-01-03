(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
open Zeroinstall
open Zeroinstall.General

module Q = Support.Qdom
module U = Support.Utils

let assert_str_equal = Fake_system.assert_str_equal

let get_sels config fake_system uri =
  fake_system#set_argv [| Test_0install.test_0install; "select"; "--xml"; uri|];
  let output = Fake_system.capture_stdout (fun () -> Main.main config.system) in
  `String (0, output) |> Xmlm.make_input |> Q.parse_input None |> Selections.create

let suite = "selections">::: [
  "selections">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let import name =
      let url = `remote_feed ("http://foo/" ^ name) in
      U.copy_file config.system (Test_0install.feed_dir +/ name) (Test_driver.cache_path_for config url) 0o644;
      Zeroinstall.Feed.update_last_checked_time config url in
    import "Source.xml";
    import "Compiler.xml";
    fake_system#set_argv [| Test_0install.test_0install; "select"; "--xml";  "--command=compile"; "--source"; "http://foo/Source.xml" |];
    let output = Fake_system.capture_stdout (fun () -> Main.main config.system) in
    let old_sels = `String (0, output) |> Xmlm.make_input |> Q.parse_input None |> Selections.create in
    let index = Selections.make_selection_map old_sels in
    let source_sel = StringMap.find_safe "http://foo/Source.xml" index in
    Q.set_attribute_ns ~prefix:"foo" ("http://namespace", "foo") "bar" source_sel;

    (* Convert to string and back to XML to check we don't lose anything. *)
    let old_xml = Selections.as_xml old_sels in
    let as_str = Q.to_utf8 old_xml in
    let s = `String (0, as_str) |> Xmlm.make_input |> Q.parse_input None in

    ZI.check_tag "selections" s;
    assert_equal 0 @@ Q.compare_nodes ~ignore_whitespace:false old_xml s;

    assert_equal "http://foo/Source.xml" @@ ZI.get_attribute "interface" s;

    let index = Selections.make_selection_map (Selections.create s) in
    assert_equal 2 @@ StringMap.cardinal index;

    let ifaces = StringMap.bindings index |> List.map fst in
    Fake_system.equal_str_lists ["http://foo/Compiler.xml"; "http://foo/Source.xml"] @@ ifaces;

    match StringMap.bindings index |> List.map snd with
    | [comp; src] -> (
        assert_str_equal "sha1=345" @@ ZI.get_attribute "id" comp;
        assert_str_equal "1.0" @@ ZI.get_attribute "version" comp;

        assert_str_equal "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" @@ ZI.get_attribute "id" src;
        assert_str_equal "1.0" @@ ZI.get_attribute "version" src;
        src.Q.attrs |> Q.AttrMap.get ("http://namespace", "foo") |> Fake_system.expect |> assert_str_equal "bar";
        assert_str_equal "1.0" @@ ZI.get_attribute "version" src;
        src.Q.attrs |> Q.AttrMap.get_no_ns "version-modifier" |> assert_equal None;

        let comp_bindings = comp |> ZI.filter_map Binding.parse_binding in
        let comp_deps = Selections.get_dependencies ~restricts:true comp in
        assert_equal [] @@ comp_bindings;
        assert_equal [] @@ comp_deps;

        let open Binding in

        let () =
          match src |> ZI.filter_map Binding.parse_binding with
          | [EnvironmentBinding {mode = Replace; source = InsertPath "."; _};
             GenericBinding b;
             GenericBinding c] ->
               assert_str_equal "/" @@ ZI.get_attribute "mount-point" b;
               assert_str_equal "source" @@ ZI.get_attribute "foo" c;
          | _ -> assert false in

        let () =
          match Selections.get_source comp with
          | Selections.CacheSelection [("sha256new", "RPUJPVVHEWJ673N736OCN7EMESYAEYM2UAY6OJ4MDFGUZ7QACLKA"); ("sha1", "345")] -> ()
          | _ -> assert false in

        match Selections.get_dependencies ~restricts:true src with
        | [dep] -> (
            assert_str_equal "http://foo/Compiler.xml" @@ ZI.get_attribute "interface" dep;
            match dep |> ZI.filter_map Binding.parse_binding with
            | [EnvironmentBinding {var_name = "PATH"; mode = Add {separator; _}; source = InsertPath "bin"};
               EnvironmentBinding {var_name = "NO_PATH"; mode = Add {separator = ","; _}; source = Value "bin"};
               EnvironmentBinding {var_name = "BINDIR"; mode = Replace; source = InsertPath "bin"};
               GenericBinding foo_binding] -> (
                 assert (separator = ";" || separator = ":");

                 assert_str_equal "compiler" @@ ZI.get_attribute "foo" foo_binding;
                 assert_equal (Some "child") @@ ZI.tag @@ List.hd foo_binding.Q.child_nodes;
                 assert_str_equal "run" @@ ZI.get_attribute "command" foo_binding;
               )
          | _ -> assert false
        )
        | _ -> assert false
    )
    | _ -> assert false
  );

  "local-path">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let iface = Test_0install.feed_dir +/ "Local.xml" in

    let index = Selections.make_selection_map (get_sels config fake_system iface) in
    let sel = StringMap.find_safe iface index in
    let () =
      match Selections.get_source sel with
      | Selections.LocalSelection local_path ->
          assert (fake_system#file_exists local_path);
      | _ -> assert false in

    let iface = Test_0install.feed_dir +/ "Local2.xml" in
    (* Add a newer implementation and try again *)
    let sels = get_sels config fake_system iface in
    let index = Selections.make_selection_map sels in
    let sel = StringMap.find_safe iface index in
    let tools = Fake_system.make_tools config in
    assert (Driver.get_unavailable_selections ~distro:tools#distro config sels <> []);

    let () =
      match Selections.get_source sel with
      | Selections.CacheSelection [("sha1", "999")] -> ()
      | _ -> assert false in

    assert_equal Feed_url.({id = "foo bar=123"; feed = `local_feed iface}) @@ Selections.get_id sel
  );

  "commands">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let iface = Test_0install.feed_dir +/ "Command.xml" in
    let sels = get_sels config fake_system iface in
    let index = Selections.make_selection_map sels in
    let sel = StringMap.find_safe iface index in

    assert_equal "c" @@ ZI.get_attribute "id" sel;
    let run = Command.get_command_ex "run" sel in
    assert_equal "test-gui" @@ ZI.get_attribute "path" run;
    run.Q.attrs |> Q.AttrMap.get ("http://custom", "attr") |> assert_equal (Some "namespaced");
    assert_equal 1 @@ List.length (run.Q.child_nodes |> List.filter (fun node -> snd node.Q.tag = "child"));

    let () =
      match Selections.get_dependencies ~restricts:true run with
      | dep :: _ ->
          let dep_impl_uri = ZI.get_attribute "interface" dep in
          let dep_impl = StringMap.find_safe dep_impl_uri index in
          assert_equal "sha1=256" @@ ZI.get_attribute "id" dep_impl;
      | _ -> assert false in

    let runexec = Test_0install.feed_dir +/ "runnable" +/ "RunExec.xml" in
    let runnable = Test_0install.feed_dir +/ "runnable" +/ "Runnable.xml" in

    fake_system#set_argv [| Test_0install.test_0install; "download"; "--offline"; "--xml"; runexec|];
    let output = Fake_system.capture_stdout (fun () -> Main.main config.system) in
    let s3 = `String (0, output) |> Xmlm.make_input |> Q.parse_input None |> Selections.create in
    let index = Selections.make_selection_map s3 in

    let runnable_impl = StringMap.find_safe runnable index in
    runnable_impl |> ZI.filter_map (fun child ->
      if ZI.tag child = Some "command" then Some (ZI.get_attribute "name" child) else None
    ) |> Fake_system.equal_str_lists ["foo"; "run"]
  );

  "old-commands">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let command_feed = Test_0install.feed_dir +/ "old-selections.xml" in
    let sels = Q.parse_file config.system command_feed |> Selections.create in

    let user_store = List.hd config.stores in
    let add_impl digest_str =
      U.makedirs config.system (user_store +/ digest_str) 0o755 in

    add_impl "sha1new=daf7bfada93ec758baeef1c714f3239ce0a5a462";
    add_impl "sha1new=3ede8dc4b83dd3d7705ee3a427b637a2cb98d789";
    add_impl "sha256=d5f30349df0fac73c4621cc3161ab125ba5f83ba9ec35e27fbb0f3a7392070eb";

    let (args, _env) = Exec.get_exec_args {config with dry_run = true} sels [] in
    match args with
    | [_; "eu.serscis.Eval"] -> ()
    | _ -> assert false
  );
]
