(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
open Support.Common
open Zeroinstall
open Zeroinstall.General
open OUnit
module F = Zeroinstall.Feed
module Q = Support.Qdom
module D = Zeroinstall.Downloader
module U = Support.Utils

let download_impls fetcher impls =
  match fetcher#download_impls impls |> Lwt_main.run with
  | `Success -> ()
  | `Aborted_by_user -> assert false

let impl_template = Impl.({
  qdom = Element.make_impl Q.AttrMap.empty;
  props = {
    attrs = Q.AttrMap.empty
      |> Q.AttrMap.add_no_ns "id" "test1"
      |> Q.AttrMap.add_no_ns "version" "1.0"
      |> Q.AttrMap.add_no_ns "from-feed" (Fake_system.test_data "test.xml");
    requires = [];
    bindings = [];
    commands = XString.Map.empty;
  };
  stability = Stability.Testing;
  os = None;
  machine = None;
  parsed_version = Zeroinstall.Version.parse "1.0";
  impl_type = `Cache_impl {
    digests = [("sha1", "123")];
    retrieval_methods = [];
  };
})

let parse_recipe s =
  let s = Printf.sprintf
      "<interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface'> \n\
        <name>Test</name> \n\
        <implementation id='sha1=123'>%s</implementation> \n\
       </interface>" s in
  let feed = `String (0, s) |> Xmlm.make_input |> Q.parse_input None |> Element.parse_feed in
  match Element.group_children feed with
  | [`Implementation impl] -> Element.retrieval_methods impl
  | _ -> assert false

let make_dl_tester () =
  let log = ref [] in
  let download_pool = D.make_pool ~max_downloads_per_site:2 in
  Queue.add download_pool Fake_system.download_pools;
  let downloader = download_pool#with_monitor Fake_system.null_ui#monitor in
  let waiting = Hashtbl.create 10 in

  (* Intercept the download and return a new blocker *)
  let handle_download ?if_slow:_ ?size:_ ?modification_time:_ _ch url =
    let blocker, waker = Lwt.wait () in
    log_info "Starting download of '%s'" url;
    log := url :: !log;
    Hashtbl.add waiting url waker;
    blocker in

  object
    method download url =
      D.interceptor := Some handle_download;
      (* Request the download *)
      U.with_switch
        (fun switch ->
           Downloader.download downloader ~switch ~hint:(`Remote_feed "testing") url >|= function
           | `Tmpfile _ -> `Success
           | (`Aborted_by_user | `Network_failure _) as x -> x
        )

    method wake url result =
      let waker = Hashtbl.find waiting url in
      Lwt.wakeup waker result

    method expect urls =
      Fake_system.equal_str_lists urls (List.rev !log);
      log := []
  end

let suite = "fetch">::: [
  "download-local">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if on_windows "mtime returns -1";
    let tools = Fake_system.make_tools config in
    let fetcher = tools#make_fetcher tools#ui#watcher in
    download_impls fetcher [];

    Fake_system.assert_error_contains "(no download locations given in feed!)"
      (fun () -> download_impls fetcher [impl_template]);

    let try_with ?(template = impl_template) ?(digest=("sha1new", "123")) xml =
      let recipe = parse_recipe xml in
      let impl_type = Impl.(`Cache_impl {
        digests = [digest];
        retrieval_methods = recipe;
      }) in
      let impl = Impl.({template with impl_type}) in
      download_impls fetcher [impl] in

    Fake_system.assert_raises_safe "Missing attribute 'dest' on <file> (generated)" @@
      lazy (try_with "<file href='mylib-1.0.jar'/>");

    let attrs = Impl.(impl_template.props.attrs |> Q.AttrMap.add_no_ns "from-feed" "http://example.com/feed.xml") in
    let remote_impl = Impl.({impl_template with props = {impl_template.props with attrs}}) in
    Fake_system.assert_raises_safe "Relative URL 'mylib-1.0.jar' in non-local feed 'http://example.com/feed.xml'" @@
      lazy (try_with ~template:remote_impl "<file href='mylib-1.0.jar' dest='lib/mylib.jar' size='100'/>");

    Fake_system.assert_raises_safe "Relative URL 'mylib-1.0.zip' in non-local feed 'http://example.com/feed.xml'" @@
      lazy (try_with ~template:remote_impl "<archive href='mylib-1.0.zip' size='100'/>");

    Fake_system.assert_error_contains "data/mylib-1.0.jar' does not exist"
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

    Fake_system.assert_error_contains "Found '..' in path 'foo/..' - disallowed"
      (fun () -> try_with "<file href='HelloWorld.zip' dest='foo/..' size='321'/>");

    let try_recipe ?digest ?error xml =
      try
        try_with ?digest @@ "<recipe><archive href='recipe-base.tgz' extract='recipe' size='305'/>" ^ xml ^ "</recipe>";
        assert (error = None);
      with Safe_exn.T e ->
        let msg = Safe_exn.msg e in
        let error = error |? lazy (Safe_exn.failf "Unexpected error '%s'" msg) in
        if not (Str.string_match (Str.regexp error) msg 0) then (
          Safe_exn.failf "Expected error '%s' but got '%s'" error msg
        ) in

    try_recipe ~digest:("sha1new", "d025d1e5c68d349f8106002e821968a5832ff008") "<rename source='rootfile' dest='somefile'/>";
    try_recipe ~error:".*disallowed" "<rename source='../somefile' dest='somefile'/>";
    try_recipe ~error:".*disallowed" "<rename source='rootfile' dest='../somefile'/>";
    try_recipe ~error:"Path /usr/bin/gpg is absolute!" "<rename source='/usr/bin/gpg' dest='gpg'/>";
    try_recipe ~error:"Path /tmp/rootfile is absolute!" "<rename source='rootfile' dest='/tmp/rootfile'/>";

    try_recipe ~digest:("sha1new", "a9415b8f35ceb4261fd1d3dc93c9514876cd817a") "<rename source='rootfile' dest='dir1/rootfile'/>";
    try_recipe ~error:"Refusing to follow non-file non-dir item.*tmp'$" "<rename source='rootfile' dest='tmp/surprise'/>";
    try_recipe ~error:"Refusing to follow non-file non-dir item.*bin'$" "<rename source='bin/gpg' dest='gpg'/>";
    try_recipe ~error:"<rename> source '.*missing-source' does not exist" "<rename source='missing-source' dest='dest'/>";

    try_recipe ~digest:("sha1new", "266fdd7055606c28b299ddc77902b81d500ce946") "<remove path='rootfile'/>";
    try_recipe ~error:"Illegal path '\\.'" "<remove path='.'/>";

    try_recipe ~digest:("sha256new", "JKORWC7SE5HS2GHWK5EU2PNMXTKUOQOODGT72WNI3CI3FSBL6QYA")
               "<file href='runnable/go.sh' dest='start.sh' executable='false' size='52'/>";
    try_recipe ~digest:("sha256new", "DOUCL455ISDBNZ5JITFFDNCTOWHRFH3JMOPU2VSOOXSEZTIAQUUQ")
               "<file href='runnable/go.sh' dest='start.sh' executable='true' size='52'/>";
  );

  "local-archive">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if on_windows "Pathnames cause trouble for tar on Windows";
    let tools = Fake_system.make_tools config in
    let fetcher = tools#make_fetcher tools#ui#watcher in

    let local_iface = Fake_system.test_data "LocalArchive.xml" in
    let root = Q.parse_file config.system local_iface |> Zeroinstall.Element.parse_feed in
    let feed = F.parse config.system root (Some local_iface) in

    let check ?error ?testfile id =
      try
        let impl = XString.Map.find_safe id (F.zi_implementations feed) in
        let digests =
          match impl.Impl.impl_type with
          | `Cache_impl {Impl.digests; _} -> digests
          | _ -> assert false in

        (* Not cached before download... *)
        assert (Stores.lookup_maybe config.system digests config.stores = None);

        download_impls fetcher [impl];
        assert (error = None);

        match testfile with
        | None -> ()
        | Some testfile ->
            (* Is cached now *)
            let path = Stores.lookup_maybe config.system digests config.stores |? lazy (failwith "missing!") in
            assert (config.system#file_exists (path +/ testfile));
      with Safe_exn.T e ->
        let msg = Safe_exn.msg e in
        let error = error |? lazy (Safe_exn.failf "Unexpected error '%s'" msg) in
        if not (Str.string_match (Str.regexp error) msg 0) then (
          Safe_exn.failf "Expected error '%s' but got '%s'" error msg
        ) in

    fake_system#set_argv @@ Array.of_list [
      Test_0install.test_0install; "select"; "--offline"; "--command="; "--xml"; local_iface
    ];
    let xml =
      Fake_system.capture_stdout (fun () ->
          let stdout = Format.std_formatter in
          Main.main ~stdout config.system
      ) in

    let sels = `String (0, xml) |> Xmlm.make_input |> Q.parse_input None |> Zeroinstall.Selections.create in
    assert (Zeroinstall.Driver.get_unavailable_selections config ~distro:tools#distro sels <> []);

    check ~error:"Local file '.*data.IDONTEXIST.tgz' does not exist" "impl2";
    check ~error:"Wrong size for .*.data.HelloWorld.tgz: feed says 177, but actually 176 bytes" "impl3";
    check ~testfile:"HelloWorld" "impl1";
    check ~testfile:"archive.tgz" "impl4";
  );

  "url-join">:: (fun () ->
    let test expected base rel =
      Fake_system.assert_str_equal expected @@ Support.Urlparse.join_url base rel in
    test "http://example.com/archive.tgz" "http://example.com/feeds/feed.xml" "/archive.tgz";
    test "http://example.com/feeds/archive.tgz" "http://example.com/feeds/feed.xml" "archive.tgz";
    test "http://example.com/archive.tgz" "http://example.com/feeds/feed.xml" "../archive.tgz";
    test "http://example.com/../archive.tgz" "http://example.com/feeds/feed.xml" "../../archive.tgz";
    test "https://example.com/archive.tgz" "https://example.com/feeds/feed.xml" "//example.com/archive.tgz";
    test "http://foo.com/archive.tgz" "https://example.com/feeds/feed.xml" "http://foo.com/archive.tgz";
    test "http://example.com/archive.tgz" "http://example.com" "archive.tgz";
    test "http://example.com/archive.tgz" "http://example.com" "/archive.tgz";
    test "http://example.com/archive.tgz?q=2" "http://example.com/?q=1/base/" "archive.tgz?q=2";
  );

  "queuing">:: (fun () ->
    Lwt_main.run (
      let tester = make_dl_tester () in

      let r1 = tester#download "http://example.com/example1" in
      let r2 = tester#download "http://example.com/example2" in
      let r3 = tester#download "http://example.com/example3" in
      let r4 = tester#download "http://example.com:8080/example4" in
      let r5 = tester#download "http://example.com/example5" in

      (* r3, r5 are queued as r1, r2 are downloading from the same site. r4 is fine. *)
      tester#wake "http://example.com:8080/example4" `Success;
      tester#expect ["http://example.com/example1"; "http://example.com/example2"; "http://example.com:8080/example4"];
      r4 >>= fun r4 -> assert_equal `Success r4;

      (* r1 succeeds, allowing r3 to start *)
      tester#wake "http://example.com/example1" `Success;
      r1 >>= fun r1 -> assert_equal `Success r1;

      tester#expect ["http://example.com/example3"];
      tester#wake "http://example.com/example3" `Success;
      r3 >>= fun r3 -> assert_equal `Success r3;

      (* r2 gets redirected and goes back on the end of the queue, allowing r5 to run. *)
      tester#wake "http://example.com/example2" @@ `Redirect "http://example.com/redirected";
      tester#expect ["http://example.com/example5"; "http://example.com/redirected"];

      (* r5 fails, allowing r2 to complete *)
      tester#wake "http://example.com/example5" @@ `Network_failure "404";
      tester#wake "http://example.com/redirected" `Success;
      r5 >>= fun r5 -> assert_equal (`Network_failure "404") r5;
      r2 >>= fun r2 -> assert_equal `Success r2;

      Lwt.return ()
    )
  );

  "redirect">:: (fun () ->
    Lwt_main.run (
      let tester = make_dl_tester () in

      let r1 = tester#download "http://example.com/example1" in
      tester#wake "http://example.com/example1" (`Redirect "file://localhost/etc/passwd");
      Fake_system.assert_raises_safe_lwt "Invalid scheme in URL 'file://localhost/etc/passwd'"
        (fun () -> r1 >|= ignore)
    )
  );

  "abort">:: (fun () ->
    Lwt_main.run (
      let pool = D.make_pool ~max_downloads_per_site:2 in
      Queue.add pool Fake_system.download_pools;
      let downloader = pool#with_monitor (fun dl -> U.async dl.D.cancel) in

      (* Intercept the download and return a new blocker *)
      let handle_download ?if_slow:_ ?size:_ ?modification_time:_ _ch url =
        let blocker, _ = Lwt.wait () in
        log_info "Starting download of '%s'" url;
        blocker in
      D.interceptor := Some handle_download;

      U.with_switch
        (fun switch ->
           Downloader.download downloader ~switch ~hint:(`Remote_feed "testing") "http://localhost/test.tgz" >|= function
           | `Tmpfile _ -> `Success
           | (`Aborted_by_user | `Network_failure _) as x -> x
        ) >|= assert_equal `Aborted_by_user
    )
  );
]
