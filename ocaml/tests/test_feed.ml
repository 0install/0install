(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
open Zeroinstall.General

module Q = Support.Qdom
module U = Support.Utils
module F = Zeroinstall.Feed
module B = Zeroinstall.Binding

let feed_of_xml system xml =
  let root = `String (0, xml) |> Xmlm.make_input |> Q.parse_input None in
  F.parse system root None

let suite = "feed">::: [
  "langs">:: (fun () ->
    let (_config, fake_system) = Fake_system.get_fake_config None in
    let system = (fake_system :> system) in
    let local_path = Test_0install.feed_dir +/ "Local.xml" in
    let root = Q.parse_file system local_path in
    let feed = F.parse system root (Some local_path) in

    let () =
      let langs = Support.Locale.score_langs @@ U.filter_map ~f:Support.Locale.parse_lang ["en_US"; "en_GB"; "fr"] in
      assert_equal 6 (Support.Locale.score_lang langs @@ Some "en_US");
      assert_equal 4 (Support.Locale.score_lang langs @@ Some "en_GB");
      assert_equal 3 (Support.Locale.score_lang langs @@ Some "en");
      assert_equal 1 (Support.Locale.score_lang langs @@ Some "fr");
      assert_equal 0 (Support.Locale.score_lang langs @@ Some "gr");
      assert_equal 3 (Support.Locale.score_lang langs @@ None) in

    let test expected langs =
      let langs = Support.Locale.score_langs @@ U.filter_map ~f:Support.Locale.parse_lang langs in
      Fake_system.assert_str_equal expected @@ Fake_system.expect @@ F.get_summary langs feed in

    test "Local feed (English GB)" ["en_GB.UTF-8"];
    test "Local feed (English)" ["en_US"];
    test "Local feed (Greek)" ["gr"];
    test "Fuente local" ["es_PT"];
    test "Local feed (English GB)" ["en_US"; "en_GB"; "es"];
    test "Local feed (English)" ["en_US"; "es"];
  );

  "feed-overrides">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let feed_url = Test_0install.feed_dir +/ "Hello.xml" in
    let digest = "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" in

    let overrides = F.load_feed_overrides config (`local_feed feed_url) in
    assert_equal None overrides.F.last_checked;
    assert_equal 0 (StringMap.cardinal overrides.F.user_stability);

    F.save_feed_overrides config (`local_feed feed_url) {
      F.user_stability = StringMap.add digest Developer overrides.F.user_stability;
      F.last_checked = Some 100.0;
    };

    (* Rating now visible *)
    let overrides = F.load_feed_overrides config (`local_feed feed_url) in
    assert_equal 1 (StringMap.cardinal overrides.F.user_stability);
    assert_equal Developer (StringMap.find digest overrides.F.user_stability);
    assert_equal (Some 100.0) overrides.F.last_checked;
  );

  "command">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let path = Test_0install.feed_dir +/ "Command.xml" in
    let root = Q.parse_file config.system path in
    let feed = F.parse config.system root (Some path) in

    let path name impl =
      let command = StringMap.find name impl.F.props.F.commands in
      ZI.get_attribute "path" command.F.command_qdom in

    let a = StringMap.find "a" feed.F.implementations in
    Fake_system.assert_str_equal "foo" @@ path "run" a;
    Fake_system.assert_str_equal "test-foo" @@ path "test" a;

    let b = StringMap.find "b" feed.F.implementations in
    Fake_system.assert_str_equal "bar" @@ path "run" b;
    Fake_system.assert_str_equal "test-foo" @@ path "test" b;

    let c = StringMap.find "c" feed.F.implementations in
    Fake_system.assert_str_equal "test-gui" @@ path "run" c;
    Fake_system.assert_str_equal "test-baz" @@ path "test" c;
  );

  "lang">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let xml = "<?xml version='1.0' ?>\n\
      <interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>\n\
        <name>Foo</name>\n\
        <summary>Foo</summary>\n\
        <description>Foo</description>\n\
        <feed langs='fr en_GB' src='http://localhost/feed.xml'/>\n\
        <group>\n\
          <group langs='fr en_GB'>\n\
            <implementation id='sha1=124' version='2' langs='fr'/>\n\
            <implementation id='sha1=234' version='2'/>\n\
          </group>\n\
          <implementation id='sha1=345' version='2'/>\n\
        </group>\n\
      </interface>" in
    let root = `String (0, xml) |> Xmlm.make_input |> Q.parse_input None in
    let feed = F.parse config.system root (Some "/local.xml") in
    begin match StringMap.bindings feed.F.implementations with
    | [("sha1=124", s124); ("sha1=234", s234); ("sha1=345", s345)] ->
        assert_equal [("fr", None)] @@ F.get_langs s124;
        assert_equal [("fr", None); ("en", Some "gb")] @@ F.get_langs s234;
        assert_equal [("en", None)] @@ F.get_langs s345;
    | _ -> assert false end;

    begin match feed.F.imported_feeds with
    | [subfeed] -> assert_equal (Some ["fr"; "en_GB"]) subfeed.F.feed_langs
    | _ -> assert false end;
  );

  "bindings">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let xml = "<?xml version='1.0' ?>\n\
      <interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>\n\
        <name>Foo</name>\n\
        <summary>Foo</summary>\n\
        <description>Foo</description>\n\
        <group>\n\
         <requires interface='http://example.com/foo.xml'>\n\
           <environment name='PATH' insert='bin'/>\n\
           <environment name='PATH' insert='bin' mode='prepend'/>\n\
           <environment name='PATH' insert='bin' default='/bin' mode='append'/>\n\
           <environment name='PATH' insert='bin' mode='replace'/>\n\
           <environment name='PATH' insert='bin' separator=',' />\n\
         </requires>\n\
         <implementation id='sha1=123' version='1'>\n\
           <environment name='SELF' insert='.' mode='replace'/>\n\
         </implementation>\n\
        </group>\n\
      </interface>" in
    let root = `String (0, xml) |> Xmlm.make_input |> Q.parse_input None in
    let feed = F.parse config.system root (Some "/local.xml") in

    begin match StringMap.bindings feed.F.implementations with
    | [("sha1=123", impl)] ->
        begin match impl.F.props.F.bindings |> List.map B.parse_binding with
        | [Some B.EnvironmentBinding {B.mode = B.Replace; _}] -> ()
        | _ -> assert false end;

        begin match impl.F.props.F.requires with
        | [dep] ->
            begin match ZI.filter_map dep.F.dep_qdom ~f:B.parse_binding with
            [
              B.EnvironmentBinding ({ B.mode = B.Add {B.pos = B.Prepend; _ }; _ } as b0);
              B.EnvironmentBinding ({ B.mode = B.Add {B.pos = B.Prepend; B.default = None; _ }; _ });
              B.EnvironmentBinding ({ B.mode = B.Add {B.pos = B.Append; B.default = Some "/bin"; _ }; _ });
              B.EnvironmentBinding ({ B.mode = B.Replace; _ });
              B.EnvironmentBinding ({ B.mode = B.Add {B.pos = B.Prepend; _ }; _ } as b4);
            ] as bindings ->
              bindings |> List.iter (function
                | B.EnvironmentBinding { B.var_name = "PATH"; B.source = B.InsertPath "bin"; _ } -> ()
                | _ -> assert false
              );

              let env = Hashtbl.create 10 in
              let impls = StringMap.singleton "http://example.com/" ((), Some "/impl") in

              let check ?old binding =
                begin match old with
                | None -> Hashtbl.remove env "PATH"
                | Some old -> Hashtbl.replace env "PATH" old end;
                B.do_env_binding env impls "http://example.com/" binding;
                Hashtbl.find env "PATH" in

              Fake_system.assert_str_equal "/impl/bin:/bin:/usr/bin" @@ check b0;
              Fake_system.assert_str_equal "/impl/bin:current" @@ check b0 ~old:"current";
              Fake_system.assert_str_equal "/impl/bin,current" @@ check b4 ~old:"current";
            | _ -> assert false end
        | _ -> assert false end
    | _ -> assert false end
  );

  "env-modes">:: (fun () ->
    let prepend = {
      B.var_name = "PYTHONPATH";
      B.source = B.InsertPath "lib";
      B.mode = B.Add { B.pos = B.Prepend; B.default = None; B.separator = ":" };
    } in

    let check ?impl ?old binding =
      let env = Hashtbl.create 1 in
      let impls = StringMap.singleton "http://example.com/" ((), impl) in
      old |> if_some (Hashtbl.replace env binding.B.var_name);
      B.do_env_binding env impls "http://example.com/" binding;
      Hashtbl.find env binding.B.var_name in

    Fake_system.assert_str_equal "/impl/lib:/usr/lib" @@ check prepend ~impl:"/impl" ~old:"/usr/lib";
    Fake_system.assert_str_equal "/impl/lib" @@ check prepend ~impl:"/impl";

    let append = {
      B.var_name = "PYTHONPATH";
      B.source = B.InsertPath "lib";
      B.mode = B.Add { B.pos = B.Append; B.default = Some "/opt/lib"; B.separator = ":" };
    } in

    Fake_system.assert_str_equal "/usr/lib:/impl/lib" @@ check append ~impl:"/impl" ~old:"/usr/lib";
    Fake_system.assert_str_equal "/opt/lib:/impl/lib" @@ check append ~impl:"/impl";

    let append = {
      B.var_name = "PYTHONPATH";
      B.source = B.InsertPath "lib";
      B.mode = B.Replace;
    } in
    Fake_system.assert_str_equal "/impl/lib" @@ check append ~impl:"/impl" ~old:"/usr/lib";
    Fake_system.assert_str_equal "/impl/lib" @@ check append ~impl:"/impl";
  );

  "requires-version">:: (fun () ->
    let system = (new Fake_system.fake_system None :> system) in
    let feed = feed_of_xml system "<?xml version='1.0' ?>\n\
      <interface last-modified='1110752708'\n\
       uri='http://foo'\n\
       xmlns='http://zero-install.sourceforge.net/2004/injector/interface'\n\
       xmlns:my='http://my/namespace'>\n\
        <name>Foo</name>\n\
        <summary>Foo</summary>\n\
        <description>Foo</description>\n\
        <group>\n\
         <requires interface='http://localhost/bar' my:foo='test'>\n\
           <version not-before='2.3.4' before='3.4.5'/>\n\
         </requires>\n\
         <implementation id='sha1=123' version='1'/>\n\
         <requires interface='http://localhost/bar2'/>\n\
        </group>\n\
      </interface>" in

    match feed.F.implementations |> StringMap.bindings with
    | [("sha1=123", impl)] ->
        begin match impl.F.props.F.requires with
        | [dep; dep2] ->
            begin match dep.F.dep_restrictions with
            | [res] -> Fake_system.assert_str_equal "version 2.3.4..!3.4.5" @@ res#to_string;
            | _ -> assert false end;
            assert_equal [] dep2.F.dep_restrictions;

            assert_equal (Some "test") @@ Q.get_attribute_opt ("http://my/namespace", "foo") dep.F.dep_qdom;
            assert_equal None @@ Q.get_attribute_opt ("http://my/namespace", "food") dep.F.dep_qdom;
        | _ -> assert false end;
    | _ -> assert false
  );

  "versions">:: (fun () ->
    let system = (new Fake_system.fake_system None :> system) in
    let feed = feed_of_xml system "<?xml version='1.0' ?>\n\
      <interface\n\
       uri='http://foo'\n\
       xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>\n\
        <name>Foo</name>\n\
        <summary>Foo</summary>\n\
        <description>Foo</description>\n\
        <implementation id='sha1=123' version='1.0-rc3' version-modifier='-pre'/>\n\
        <implementation id='skipped' if-0install-version='..!1 | 2'/>\n\
        <implementation id='used' version='2' if-0install-version='1..'/>\n\
      </interface>" in

    match feed.F.implementations |> StringMap.bindings with
    | [("sha1=123", impl); ("used", used)] ->
        Fake_system.assert_str_equal "1.0-rc3-pre" @@ Zeroinstall.Versions.format_version impl.F.parsed_version;
        Fake_system.assert_str_equal "2" @@ Zeroinstall.Versions.format_version used.F.parsed_version;
    | _ -> assert false
  );

  "attrs">:: (fun () ->
    let system = (new Fake_system.fake_system None :> system) in
    let feed = feed_of_xml system "<?xml version='1.0' ?>\n\
      <interface last-modified='1110752708'\n\
       uri='http://foo'\n\
       xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>\n\
        <name>Foo</name>\n\
        <summary>Foo</summary>\n\
        <description>Foo</description>\n\
        <group main='bin/sh' foo='foovalue' xmlns:bobpre='http://bob' bobpre:bob='bobvalue'>\n\
         <implementation id='sha1=123' version='1' bobpre:bob='newbobvalue'/>\n\
         <implementation id='sha1=124' version='2' main='next'/>\n\
        </group>\n\
      </interface>" in

    match feed.F.implementations |> StringMap.bindings with
    | [("sha1=123", impl1); ("sha1=124", impl2)] ->
        let check expected name impl =
          let attr =
            try F.AttrMap.find name impl.F.props.F.attrs
            with Not_found -> "" in
          Fake_system.assert_str_equal expected attr in

        check "foovalue" ("", "foo") impl1;
        check "bin/sh" ("", "main") impl1;
        check "newbobvalue" ("http://bob", "bob") impl1;

        check "bobvalue" ("http://bob", "bob") impl2;
        check "next" ("", "main") impl2
    | _ -> assert false
  );

  "cant-use-both-insert-and-value-in-environment-binding">:: (fun () ->
    let system = (new Fake_system.fake_system None :> system) in
    Fake_system.assert_raises_safe "Can't use 'insert' and 'value' together on  <environment> (generated)" (lazy (
      ignore @@
      feed_of_xml system "<?xml version='1.0' ?>\n\
        <interface last-modified='1110752708'\n\
         uri='http://foo'\n\
         xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>\n\
          <name>Foo</name>\n\
          <summary>Foo</summary>\n\
          <description>Foo</description>\n\
          <group>\n\
           <requires interface='http://foo2'>\n\
            <environment name='DATA' value='' insert=''/>\n\
           </requires>\n\
           <implementation id='sha1=123' version='1'/>\n\
          </group>\n\
        </interface>"
    ))
  );
]
