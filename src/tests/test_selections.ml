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
  let output = Fake_system.capture_stdout (fun () ->
      let stdout = Format.std_formatter in
      Main.main ~stdout config.system
    ) in
  `String (0, output) |> Xmlm.make_input |> Q.parse_input None |> Selections.create

let get_bindings sels =
  let result = ref [] in
  sels |> Selections.iter (fun iface sel -> result := (iface, sel) :: !result);
  List.rev !result

let get_dependencies elem =
  Element.deps_and_bindings elem |> List.filter (function
    | #Element.dependency -> true
    | _ -> false
  )

let binary iface = {Selections.iface; source = false}

let suite = "selections">::: [
  "selections">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let import name =
      let url = `Remote_feed ("http://foo/" ^ name) in
      U.copy_file config.system (Fake_system.test_data name) (Test_driver.cache_path_for config url) 0o644;
      Zeroinstall.Feed_metadata.update_last_checked_time config url in
    import "Source.xml";
    import "Compiler.xml";
    fake_system#set_argv [| Test_0install.test_0install; "select"; "--xml";  "--command=compile"; "--source"; "http://foo/Source.xml" |];
    let output = Fake_system.capture_stdout (fun () ->
        let stdout = Format.std_formatter in
        Main.main ~stdout config.system
      ) in
    let old_sels = `String (0, output) |> Xmlm.make_input |> Q.parse_input None in
    let old_sels = {old_sels with
      Q.child_nodes = old_sels.Q.child_nodes |> List.map (fun sel ->
        if sel |> ZI.get_attribute "interface" = "http://foo/Source.xml" then
          {sel with Q.attrs = Q.AttrMap.add ("http://namespace", "foo") ~prefix:"foo" "bar" sel.Q.attrs}
        else sel
      )
    }
    |> Selections.create in

    (* Convert to string and back to XML to check we don't lose anything. *)
    let old_xml = Selections.as_xml old_sels in
    let as_str = Q.to_utf8 old_xml in
    let s = `String (0, as_str) |> Xmlm.make_input |> Q.parse_input None in

    ZI.check_tag "selections" s;
    assert_equal 0 @@ Q.compare_nodes ~ignore_whitespace:false old_xml s;

    assert_equal "http://foo/Source.xml" @@ ZI.get_attribute "interface" s;

    let bindings = Selections.create s |> get_bindings in
    assert_equal 2 @@ List.length bindings;

    let ifaces = bindings |> List.map (fun (role, _impl) -> role.Selections.iface) in
    Fake_system.equal_str_lists ["http://foo/Compiler.xml"; "http://foo/Source.xml"] @@ ifaces;

    match List.map snd bindings with
    | [comp; src] -> (
        assert_str_equal "sha1=345" @@ Element.id comp;
        assert_str_equal "1.0" @@ Element.version comp;

        assert_str_equal "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" @@ Element.id src;
        assert_str_equal "1.0" @@ Element.version src;
        (Element.as_xml src).Q.attrs |> Q.AttrMap.get ("http://namespace", "foo") |> Fake_system.expect |> assert_str_equal "bar";
        assert_str_equal "1.0" @@ Element.version src;
        (Element.as_xml src).Q.attrs |> Q.AttrMap.get_no_ns "version-modifier" |> assert_equal None;

        let comp_bindings = Element.bindings comp |> List.map Binding.parse_binding in
        let comp_deps = get_dependencies comp in
        assert_equal [] @@ comp_bindings;
        assert_equal [] @@ comp_deps;

        let open Binding in

        let () =
          match Element.bindings src |> List.map Binding.parse_binding with
          | [EnvironmentBinding {mode = Replace; source = InsertPath "."; _};
             GenericBinding b;
             GenericBinding c] ->
               assert_str_equal "/" @@ ZI.get_attribute "mount-point" (Element.as_xml b);
               assert_str_equal "source" @@ ZI.get_attribute "foo" (Element.as_xml c);
          | _ -> assert false in

        let () =
          match Selections.get_source comp with
          | Selections.CacheSelection [("sha256new", "RPUJPVVHEWJ673N736OCN7EMESYAEYM2UAY6OJ4MDFGUZ7QACLKA"); ("sha1", "345")] -> ()
          | _ -> assert false in

        match get_dependencies src with
        | [`Requires dep] -> (
            assert_str_equal "http://foo/Compiler.xml" @@ Element.interface dep;
            match Element.bindings dep |> List.map Binding.parse_binding with
            | [EnvironmentBinding {var_name = "PATH"; mode = Add {separator; _}; source = InsertPath "bin"};
               EnvironmentBinding {var_name = "NO_PATH"; mode = Add {separator = ","; _}; source = Value "bin"};
               EnvironmentBinding {var_name = "BINDIR"; mode = Replace; source = InsertPath "bin"};
               GenericBinding foo_binding] -> (
                 assert (separator = ";" || separator = ":");
                 let foo_binding = Element.as_xml foo_binding in

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
    let iface = Fake_system.test_data "Local.xml" in

    let index = get_sels config fake_system iface in
    let sel = Selections.get_selected_ex (binary iface) index in
    let () =
      match Selections.get_source sel with
      | Selections.LocalSelection local_path ->
          assert (fake_system#file_exists local_path);
      | _ -> assert false in

    let iface = Fake_system.test_data "Local2.xml" in
    (* Add a newer implementation and try again *)
    let sels = get_sels config fake_system iface in
    let sel = Selections.get_selected_ex (binary iface) sels in
    let tools = Fake_system.make_tools config in
    assert (Driver.get_unavailable_selections ~distro:tools#distro config sels <> []);

    let () =
      match Selections.get_source sel with
      | Selections.CacheSelection [("sha1", "999")] -> ()
      | _ -> assert false in

    assert_equal Feed_url.({id = "foo bar=123"; feed = `Local_feed iface}) @@ Selections.get_id sel
  );

  "commands">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let iface = Fake_system.test_data "Command.xml" in
    let sels = get_sels config fake_system iface in
    let sel = Selections.get_selected_ex (binary iface) sels in

    assert_equal "c" @@ Element.id sel;
    let run = Element.get_command_ex "run" sel in
    assert_equal (Some "test-gui") @@ Element.path run;
    (Element.as_xml run).Q.attrs |> Q.AttrMap.get ("http://custom", "attr") |> assert_equal (Some "namespaced");
    assert_equal 1 @@ List.length ((Element.as_xml run).Q.child_nodes |> List.filter (fun node -> snd node.Q.tag = "child"));

    let () =
      match Element.command_children run with
      | `Requires dep :: _ ->
          let dep_impl_uri = Element.interface dep in
          let dep_impl = Selections.get_selected_ex (binary dep_impl_uri) sels in
          assert_equal "sha1=256" @@ Element.id dep_impl;
      | _ -> assert false in

    let runexec = Fake_system.test_data "runnable" +/ "RunExec.xml" in
    let runnable = Fake_system.test_data "runnable" +/ "Runnable.xml" in

    fake_system#set_argv [| Test_0install.test_0install; "download"; "--offline"; "--xml"; runexec|];
    let output = Fake_system.capture_stdout (fun () ->
        let stdout = Format.std_formatter in
        Main.main ~stdout config.system
      ) in
    let s3 = `String (0, output) |> Xmlm.make_input |> Q.parse_input None |> Selections.create in

    let runnable_impl = Selections.get_selected_ex (binary runnable) s3 in
    Element.deps_and_bindings runnable_impl |> List.filter_map (function
      | `Command child -> Some (Element.command_name child)
      | _ -> None
    ) |> Fake_system.equal_str_lists ["foo"; "run"]
  );

  "old-commands">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let command_feed = Fake_system.test_data "old-selections.xml" in
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

  "source-sel">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let feed = Fake_system.test_data "source-sel.xml" in
    let sels = Q.parse_file config.system feed |> Selections.create in
    Format.asprintf "%a@." (Tree.print config) sels |> assert_str_equal
       "- URI: /test/BuildDepSource.xml\
      \n  Version: 1\
      \n  Path: /test\
      \n  \
      \n  - URI: /test/S2.xml#source\
      \n    Version: 1.0\
      \n    Path: /test\
      \n";

    match Selections.collect_bindings sels with
    | [(_, `Environment s2_self); (_, `Environment s2_dep)] ->
        Element.binding_name s2_dep |> assert_str_equal "key";
        Element.binding_name s2_self |> assert_str_equal "S2";
    | _ -> assert false
  );
]
