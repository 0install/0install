(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open Zeroinstall.General
open OUnit
module Fetch = Zeroinstall.Fetch
module F = Zeroinstall.Feed
module Recipe = Zeroinstall.Recipe
module Q = Support.Qdom

let download_impls fetcher impls =
  match fetcher#download_impls impls |> Lwt_main.run with
  | `success -> ()
  | `aborted_by_user -> assert false

let impl_template = F.({
  qdom = ZI.make_root "implementation";
  props = {
    attrs = F.AttrMap.singleton ("", "id") "test1"
      |> F.AttrMap.add ("", "version") "1.0"
      |> F.AttrMap.add ("", "from-feed") (Test_0install.feed_dir +/ "test.xml");
    requires = [];
    bindings = [];
    commands = StringMap.empty;
  };
  stability = Testing;
  os = None;
  machine = None;
  parsed_version = Zeroinstall.Versions.parse_version "1.0";
  impl_type = CacheImpl {
    digests = [("sha1", "123")];
    retrieval_methods = [];
  };
})

let parse_xml s =
  let s = "<root xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>" ^ s ^ "</root>" in
  let root = `String (0, s) |> Xmlm.make_input |> Q.parse_input None in
  List.hd root.Q.child_nodes

let suite = "fetch">::: [
  "download-local">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let driver = Fake_system.make_driver config in
    let fetcher = driver#fetcher in
    download_impls fetcher [];

    Fake_system.assert_error_contains "(no download locations given in feed!)"
      (fun () -> download_impls fetcher [impl_template]);

    let try_with ?(template = impl_template) ?(digest=("sha1new", "123")) xml =
      let recipe = parse_xml xml in
      let impl_type = F.(CacheImpl {
        digests = [digest];
        retrieval_methods = [recipe];
      }) in
      let impl = F.({template with impl_type}) in
      download_impls fetcher [impl] in

    Fake_system.assert_raises_safe "Missing attribute 'dest' on <file> (generated)" @@
      lazy (try_with "<file href='mylib-1.0.jar'/>");

    let attrs = F.(impl_template.props.attrs |> AttrMap.add ("", "from-feed") "http://example.com/feed.xml") in
    let remote_impl = F.({impl_template with props = {impl_template.props with attrs}}) in
    Fake_system.assert_raises_safe "Relative URL 'mylib-1.0.jar' in non-local feed 'http://example.com/feed.xml'" @@
      lazy (try_with ~template:remote_impl "<file href='mylib-1.0.jar' dest='lib/mylib.jar' size='100'/>");

    Fake_system.assert_error_contains "tests/mylib-1.0.jar' does not exist"
      (fun () -> try_with "<file href='mylib-1.0.jar' dest='lib/mylib.jar' size='100'/>");

    Fake_system.assert_error_contains "feed says 100, but actually 321 bytes"
      (fun () -> try_with "<file href='HelloWorld.zip' dest='lib/mylib.jar' size='100'/>");

    Fake_system.assert_error_contains "Required digest: sha1new=123"
      (fun () -> try_with "<file href='HelloWorld.zip' dest='lib/mylib.jar' size='321'/>");

    try_with ~digest:("sha1new", "9db418be7ccca3cfd12649ca2822cb618c166e1e") "<file href='HelloWorld.zip' dest='lib/mylib.jar' size='321'/>";

    try_with ~digest:("sha1new", "290eb133e146635fe37713fd58174324a16d595f") "<archive href='HelloWorld.zip' size='321'/>";

    Fake_system.assert_error_contains "Path /lib/mylib.jar is absolute!"
      (fun () -> try_with "<file href='HelloWorld.zip' dest='/lib/mylib.jar' size='321'/>");

    Fake_system.assert_error_contains "Illegal path '.'"
      (fun () -> try_with "<file href='HelloWorld.zip' dest='.' size='321'/>");

    Fake_system.assert_error_contains "Illegal path ''"
      (fun () -> try_with "<file href='HelloWorld.zip' dest='' size='321'/>");

    Fake_system.assert_error_contains "Found '..' in path 'foo/..' - disallowed"
      (fun () -> try_with "<file href='HelloWorld.zip' dest='foo/..' size='321'/>");
  );
]
