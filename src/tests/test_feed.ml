(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
open Support.Common
open OUnit
open Zeroinstall.General
open Zeroinstall

module Q = Support.Qdom
module U = Support.Utils
module F = Zeroinstall.Feed
module B = Zeroinstall.Binding

let feed_of_xml system xml =
  let root = `String (0, xml) |> Xmlm.make_input |> Q.parse_input None |> Element.parse_feed in
  F.parse system root None

let make_env k = function
  | None -> Env.empty
  | Some v -> Env.empty |> Env.put k v

let suite = "feed">::: [
  "langs">:: (fun () ->
    let (_config, fake_system) = Fake_system.get_fake_config None in
    let system = (fake_system :> system) in
    let local_path = Fake_system.test_data "Local.xml" in
    let root = Q.parse_file system local_path |> Element.parse_feed in
    let feed = F.parse system root (Some local_path) in

    let () =
      let langs = Support.Locale.score_langs @@ List.filter_map Support.Locale.parse_lang ["en_US"; "en_GB"; "fr"] in
      assert_equal 6 (Support.Locale.score_lang langs @@ Some "en_US");
      assert_equal 4 (Support.Locale.score_lang langs @@ Some "en_GB");
      assert_equal 3 (Support.Locale.score_lang langs @@ Some "en");
      assert_equal 1 (Support.Locale.score_lang langs @@ Some "fr");
      assert_equal 0 (Support.Locale.score_lang langs @@ Some "gr");
      assert_equal 3 (Support.Locale.score_lang langs @@ None) in

    let test ?description expected langs =
      let langs = Support.Locale.score_langs @@ List.filter_map Support.Locale.parse_lang langs in
      Fake_system.assert_str_equal expected @@ Fake_system.expect @@ F.get_summary langs feed;
      description |> if_some (fun d ->
        Fake_system.assert_str_equal d @@ Fake_system.expect @@ F.get_description langs feed
      ) in

    test "Local feed (English GB)" ["en_GB.UTF-8"];
    test "Local feed (English)" ["en_US"];
    test "Local feed (Greek)" ["gr"];
    test ~description:"Español" "Fuente local" ["es_PT"];
    test "Local feed (English GB)" ["en_US"; "en_GB"; "es"];
    test ~description:"English" "Local feed (English)" ["en_US"; "es"];
  );

  "feed-overrides">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let feed_url = Fake_system.test_data "Hello.xml" in
    let digest = "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" in

    let overrides = Feed_metadata.load config (`Local_feed feed_url) in
    assert_equal None overrides.Feed_metadata.last_checked;
    assert_equal 0 (XString.Map.cardinal overrides.Feed_metadata.user_stability);

    Feed_metadata.save config (`Local_feed feed_url) { Feed_metadata.
      user_stability = XString.Map.add digest Stability.Developer overrides.Feed_metadata.user_stability;
      last_checked = Some 100.0;
    };

    (* Rating now visible *)
    let overrides = Feed_metadata.load config (`Local_feed feed_url) in
    assert_equal 1 (XString.Map.cardinal overrides.Feed_metadata.user_stability);
    assert_equal Stability.Developer (XString.Map.find_safe digest overrides.Feed_metadata.user_stability);
    assert_equal (Some 100.0) overrides.Feed_metadata.last_checked;
  );

  "command">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let path = Fake_system.test_data "Command.xml" in
    let root = Q.parse_file config.system path |> Element.parse_feed in
    let feed = F.parse config.system root (Some path) in

    let path name impl =
      let command = XString.Map.find_safe name impl.Impl.props.Impl.commands in
      Element.path command.Impl.command_qdom |> Fake_system.expect in

    let a = XString.Map.find_safe "a" (F.zi_implementations feed) in
    Fake_system.assert_str_equal "foo" @@ path "run" a;
    Fake_system.assert_str_equal "test-foo" @@ path "test" a;

    let b = XString.Map.find_safe "b" (F.zi_implementations feed) in
    Fake_system.assert_str_equal "bar" @@ path "run" b;
    Fake_system.assert_str_equal "test-foo" @@ path "test" b;

    let c = XString.Map.find_safe "c" (F.zi_implementations feed) in
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
    let root = `String (0, xml) |> Xmlm.make_input |> Q.parse_input None |> Element.parse_feed in
    let feed = F.parse config.system root (Some "/local.xml") in
    begin match XString.Map.bindings (F.zi_implementations feed) with
    | [("sha1=124", s124); ("sha1=234", s234); ("sha1=345", s345)] ->
        assert_equal [("fr", None)] @@ Impl.get_langs s124;
        assert_equal [("fr", None); ("en", Some "gb")] @@ Impl.get_langs s234;
        assert_equal [("en", None)] @@ Impl.get_langs s345;
    | _ -> assert false end;

    begin match F.imported_feeds feed with
    | [subfeed] -> assert_equal (Some ["fr"; "en_GB"]) subfeed.Feed_import.langs
    | _ -> assert false end;
  );

  "bindings">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if on_windows "Tests use Unix paths";
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
    let root = `String (0, xml) |> Xmlm.make_input |> Q.parse_input None |> Element.parse_feed in
    let feed = F.parse config.system root (Some "/local.xml") in

    begin match XString.Map.bindings (F.zi_implementations feed) with
    | [("sha1=123", impl)] ->
        begin match impl.Impl.props.Impl.bindings |> List.map Element.classify_binding |> List.map B.parse_binding with
        | [B.EnvironmentBinding {B.mode = B.Replace; _}] -> ()
        | _ -> assert false end;

        begin match impl.Impl.props.Impl.requires with
        | [dep] ->
            begin match Element.bindings dep.Impl.dep_qdom |> List.map B.parse_binding with
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

              let check ?old binding =
                let env = ref @@ make_env "PATH" old in
                B.do_env_binding env (lazy ((), Some "/impl")) binding;
                Env.get_exn "PATH" !env in

              Fake_system.assert_str_equal "/impl/bin:/bin:/usr/bin" @@ check b0;
              Fake_system.assert_str_equal "/impl/bin:current" @@ check b0 ~old:"current";
              Fake_system.assert_str_equal "/impl/bin,current" @@ check b4 ~old:"current";
            | _ -> assert false end
        | _ -> assert false end
    | _ -> assert false end
  );

  "env-modes">:: (fun () ->
    skip_if on_windows "Tests use Unix paths";
    let prepend = {
      B.var_name = "PYTHONPATH";
      B.source = B.InsertPath "lib";
      B.mode = B.Add { B.pos = B.Prepend; B.default = None; B.separator = ":" };
    } in

    let check ?impl ?old binding =
      let env = ref @@ make_env binding.B.var_name old in
      B.do_env_binding env (lazy ((), impl)) binding;
      Env.get_exn binding.B.var_name !env in

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

    match F.zi_implementations feed |> XString.Map.bindings with
    | [("sha1=123", impl)] ->
        begin match impl.Impl.props.Impl.requires with
        | [dep; dep2] ->
            begin match dep.Impl.dep_restrictions with
            | [res] -> Fake_system.assert_str_equal "version 2.3.4..!3.4.5" @@ res#to_string;
            | _ -> assert false end;
            assert_equal [] dep2.Impl.dep_restrictions;

            (Element.as_xml dep.Impl.dep_qdom).Q.attrs |> Q.AttrMap.get ("http://my/namespace", "foo") |> assert_equal (Some "test");
            (Element.as_xml dep.Impl.dep_qdom).Q.attrs |> Q.AttrMap.get ("http://my/namespace", "food") |> assert_equal None;
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

    match F.zi_implementations feed |> XString.Map.bindings with
    | [("sha1=123", impl); ("used", used)] ->
        Fake_system.assert_str_equal "1.0-rc3-pre" @@ Zeroinstall.Version.to_string impl.Impl.parsed_version;
        Fake_system.assert_str_equal "2" @@ Zeroinstall.Version.to_string used.Impl.parsed_version;
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

    match F.zi_implementations feed |> XString.Map.bindings with
    | [("sha1=123", impl1); ("sha1=124", impl2)] ->
        let check expected name impl =
          let attr = Q.AttrMap.get name impl.Impl.props.Impl.attrs |> default "" in
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

  "min-injector-version">:: (fun () ->
    let system = (new Fake_system.fake_system None :> system) in
    let test attr =
      ignore @@ feed_of_xml system (Printf.sprintf "<?xml version='1.0' ?>\n\
        <interface last-modified='1110752708'\n\
        uri='http://foo' %s\n\
         xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>\n\
          <name>Foo</name>\n\
          <summary>Foo</summary>\n\
          <description>Foo</description>\n\
        </interface>" attr) in

    test "";
    test "min-injector-version='0.19'";
    Fake_system.assert_raises_safe "Feed requires 0install version 1000 or later (we are .*" (lazy (
      test "min-injector-version='1000'"
    ))
  );

  "replaced">:: (fun () ->
    let system = (new Fake_system.fake_system None :> system) in
    let iface = Fake_system.test_data "Replaced.xml" in
    let root = Q.parse_file system iface |> Element.parse_feed in
    let feed = F.parse system root (Some iface) in
    Fake_system.assert_str_equal "http://localhost:8000/Hello" (Fake_system.expect (F.replacement feed))
  );
]
