(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall
open Zeroinstall.General
open Support.Common
open OUnit
module Q = Support.Qdom
open Fake_system
module Distro = Zeroinstall.Distro
module Distro_impls = Zeroinstall.Distro_impls
module Impl = Zeroinstall.Impl
module F = Zeroinstall.Feed
module U = Support.Utils

let is_available_locally config impl =
  let open Impl in
  match impl.impl_type with
  | `Package_impl {package_state;_} -> package_state = `Installed
  | `Local_impl path -> config.system#file_exists path
  | `Cache_impl {digests;_} ->
      match Zeroinstall.Stores.lookup_maybe config.system digests config.stores with
      | None -> false
      | Some _path -> true

let parse_xml s =
  let s = "<root xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>" ^ s ^ "</root>" in
  let root = `String (0, s) |> Xmlm.make_input |> Q.parse_input None in
  List.hd root.Q.child_nodes

let test_feed = "<?xml version='1.0'?>\n\
<interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface' uri='http://repo.roscidus.com/python/python'>\n\
  <name>Test</name>\n\
\n\
  <package-implementation distributions='Cygwin' main='/usr/bin/python' package='python'/>\n\
\n\
  <package-implementation distributions='RPM' main='/usr/bin/python' package='python'/>\n\
  <package-implementation distributions='RPM' main='/usr/bin/python3' package='python3'/>\n\
  <package-implementation distributions='Gentoo' main='/usr/bin/python' package='dev-lang/python'/>\n\
\n\
  <package-implementation distributions='Debian' main='/usr/bin/python2.7' package='python2.7'/>\n\
  <package-implementation distributions='Debian' main='/usr/bin/python3' package='python3'/>\n\
\n\
  <package-implementation distributions='Arch' main='/usr/bin/python2' package='python2'/>\n\
  <package-implementation distributions='Arch' main='/usr/bin/python3' package='python'/>\n\
\n\
  <package-implementation distributions='Ports' main='/usr/local/bin/python2.6' package='python26'/>\n\
\n\
  <package-implementation distributions='MacPorts' main='/opt/local/bin/python2.7' package='python27'/>\n\
</interface>"

let test_gobject_feed = "<?xml version='1.0'?>\n\
<interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface' uri='http://repo.roscidus.com/python/python-gobject'>\n\
  <name>gobject</name>\n\
  <package-implementation package='python-idontexist'/>\n\
</interface>"

let load_feed system xml =
    let root = Q.parse_input None @@ Xmlm.make_input (`String (0, xml)) |> Element.parse_feed in
    F.parse system root None

let to_impl_list map : _ Impl.t list =
  StringMap.map_bindings (fun _ impl -> impl) map

let gimp_feed = Test_feed.feed_of_xml Fake_system.real_system "\
  <interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface' uri='http://gimp.org/gimp'>\
    <name>Gimp</name>\
    <package-implementation package='gimp'/>\
    <package-implementation package='media-gfx/gimp' distribution='Gentoo'/>\
  </interface>"

let make_test_feed package_name = Test_feed.feed_of_xml Fake_system.real_system (Printf.sprintf "\
  <interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface' uri='http://example.com/x.xml'>\
    <name>%s</name><package-implementation package='%s'/>\
  </interface>" package_name package_name)

let packagekit = lazy (Fake_distro.fake_packagekit `Ok)

let suite = "distro">::: [
  "arch">:: Fake_system.with_tmpdir (fun tmpdir ->
    skip_if (Sys.os_type = "Win32") "Paths get messed up on Windows";

    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    fake_system#add_file "/var/lib/pacman/local/python2-2.7.2-4/desc" "../tests/arch/local/python2-2.7.2-4/desc";
    fake_system#hide_path "/usr/bin/python2";
    fake_system#hide_path "/usr/bin/python3";
    assert (not @@ fake_system#file_exists "/usr/bin/python2");
    fake_system#add_dir "/bin" ["python2"; "python3"];
    let system = (fake_system :> system) in
    let distro = Distro_impls.ArchLinux.arch_distribution ~packagekit config in
    let feed = load_feed system test_feed in
    let impls = distro#get_impls_for_feed ~problem:failwith feed |> to_impl_list in
    let open Impl in
    match impls with
    | [impl] ->
        assert_str_equal "2.7.2-4" (Zeroinstall.Version.to_string impl.parsed_version);
        let run = StringMap.find_safe "run" impl.props.commands in
        assert_str_equal "/bin/python2" (Element.path run.command_qdom |> Fake_system.expect)
    | impls -> assert_failure @@ Printf.sprintf "want 1 Python, got %d" (List.length impls)
  );

  "arch2">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if (Sys.os_type = "Win32") "Paths get messed up on Windows";
    let arch_db = Test_0install.feed_dir +/ "arch" in
    let distro = Distro_impls.ArchLinux.arch_distribution ~arch_db ~packagekit config in

    distro#get_impls_for_feed ~problem:failwith gimp_feed |> to_impl_list |> assert_equal [];

    begin match distro#get_impls_for_feed ~problem:failwith (make_test_feed "zeroinstall-injector") |> to_impl_list with
    | [impl] ->
        assert_str_equal "package:arch:zeroinstall-injector:1.5-1:*" @@ Impl.get_attr_ex "id" impl;
        assert_str_equal "1.5-1" @@ Impl.get_attr_ex "version" impl
    | impls -> assert_failure @@ Printf.sprintf "want 1, got %d" (List.length impls) end;
  );

  "slack">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if (Sys.os_type = "Win32") "Paths get messed up on Windows";
    let slackdir = Test_0install.feed_dir +/ "slack" in
    let packages_dir = slackdir +/ "packages" in
    let distro = Distro_impls.Slackware.slack_distribution ~packages_dir ~packagekit config in

    distro#get_impls_for_feed ~problem:failwith gimp_feed |> to_impl_list |> assert_equal [];

    begin match distro#get_impls_for_feed ~problem:failwith (make_test_feed "infozip") |> to_impl_list with
    | [impl] ->
        assert_str_equal "package:slack:infozip:5.52-2:i486" @@ Impl.get_attr_ex "id" impl;
        assert_str_equal "5.52-2" @@ Impl.get_attr_ex "version" impl;
        assert_str_equal "i486" @@ Arch.format_machine_or_star impl.Impl.machine;
    | impls -> assert_failure @@ Printf.sprintf "want 1, got %d" (List.length impls) end;
  );

  "gentoo">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if (Sys.os_type = "Win32") "Paths get messed up on Windows";
    let pkgdir = Test_0install.feed_dir +/ "gentoo" in
    let distro = Distro_impls.Gentoo.gentoo_distribution ~pkgdir ~packagekit config in

    distro#get_impls_for_feed ~problem:failwith gimp_feed |> to_impl_list |> assert_equal [];

    begin match distro#get_impls_for_feed ~problem:failwith (make_test_feed "sys-apps/portage") |> to_impl_list with
    | [impl] ->
        assert_str_equal "package:gentoo:sys-apps/portage:2.1.7.16:x86_64" @@ Impl.get_attr_ex "id" impl;
        assert_str_equal "2.1.7.16" @@ Impl.get_attr_ex "version" impl;
        assert_str_equal "x86_64" @@ Arch.format_machine_or_star impl.Impl.machine;
    | impls -> assert_failure @@ Printf.sprintf "want 1, got %d" (List.length impls) end;

    begin match distro#get_impls_for_feed ~problem:failwith (make_test_feed "sys-kernel/gentoo-sources") |> to_impl_list with
    | [b; a] ->
        assert_str_equal "package:gentoo:sys-kernel/gentoo-sources:2.6.30-4:i686" @@ Impl.get_attr_ex "id" a;
        assert_str_equal "2.6.30-4" @@ Impl.get_attr_ex "version" a;
        assert_str_equal "i686" @@ Arch.format_machine_or_star a.Impl.machine;

        assert_str_equal "package:gentoo:sys-kernel/gentoo-sources:2.6.32:x86_64" @@ Impl.get_attr_ex "id" b;
        assert_str_equal "2.6.32" @@ Impl.get_attr_ex "version" b;
        assert_str_equal "x86_64" @@ Arch.format_machine_or_star b.Impl.machine;
    | impls -> assert_failure @@ Printf.sprintf "want 2, got %d" (List.length impls) end;

    begin match distro#get_impls_for_feed ~problem:failwith (make_test_feed "app-emulation/emul-linux-x86-baselibs") |> to_impl_list with
    | [impl] ->
        assert_str_equal "package:gentoo:app-emulation/emul-linux-x86-baselibs:20100220:i386" @@ Impl.get_attr_ex "id" impl;
        assert_str_equal "20100220" @@ Impl.get_attr_ex "version" impl;
        assert_str_equal "i386" @@ Arch.format_machine_or_star impl.Impl.machine;
    | impls -> assert_failure @@ Printf.sprintf "want 1, got %d" (List.length impls) end;
  );

  "ports">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    skip_if (Sys.os_type = "Win32") "Paths get messed up on Windows";
    let pkg_db = Test_0install.feed_dir +/ "ports" in
    let distro = Distro_impls.Ports.ports_distribution ~pkg_db ~packagekit config in

    begin match distro#get_impls_for_feed ~problem:failwith (make_test_feed "zeroinstall-injector") |> to_impl_list with
    | [impl] ->
        assert (U.starts_with (Impl.get_attr_ex "id" impl) "package:ports:zeroinstall-injector:0.41-2:");
        assert_str_equal "0.41-2" @@ Impl.get_attr_ex "version" impl
    | impls -> assert_failure @@ Printf.sprintf "want 1, got %d" (List.length impls) end;
  );

  "mac-ports">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if (Sys.os_type = "Win32") "Paths get messed up on Windows";
    fake_system#set_spawn_handler (Some Fake_system.real_spawn_handler);
    let pkgdir = Test_0install.feed_dir +/ "macports" in
    let old_path = Unix.getenv "PATH" in
    fake_system#putenv "PATH" (pkgdir ^ ":" ^ old_path);
    Unix.putenv "PATH" (pkgdir ^ ":" ^ old_path);
    let macports_db = pkgdir +/ "registry.db" in
    let distro = Distro_impls.Mac.macports_distribution ~macports_db config in

    begin match distro#get_impls_for_feed ~problem:failwith (make_test_feed "zeroinstall-injector") |> to_impl_list with
    | [impl] ->
        assert_str_equal "package:macports:zeroinstall-injector:1.0-0:*" @@ Impl.get_attr_ex "id" impl;
        assert_str_equal "1.0-0" @@ Impl.get_attr_ex "version" impl;
        assert_equal None @@ impl.Impl.machine
    | impls -> assert_failure @@ Printf.sprintf "want 1, got %d" (List.length impls) end;

    Unix.putenv "PATH" old_path;
  );

  "test_host_python">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in

    let python_path =
      Support.Utils.find_in_path Fake_system.real_system "python"
      |? lazy (skip_if true "Python not installed"; assert false) in
    fake_system#add_file python_path python_path;

    fake_system#set_spawn_handler (Some Fake_system.real_spawn_handler);

    let distro = Distro_impls.generic_distribution ~packagekit config in

    let open Impl in
    let is_host (id, _impl) = U.starts_with id "package:host:" in
    let find_host impls =
      try impls |> StringMap.bindings |> List.find is_host |> snd
      with Not_found -> assert_failure "No host package found!" in

    let root = Q.parse_input None @@ Xmlm.make_input (`String (0, test_feed)) |> Element.parse_feed in
    let feed = F.parse system root None in
    let () =
      let impls = distro#get_impls_for_feed ~problem:failwith feed in
      let host_python = find_host impls in
      let python_run =
        try StringMap.find_nf "run" host_python.props.commands
        with Not_found -> assert_failure "No run command for host Python" in
      assert (Fake_system.real_system#file_exists (Element.path python_run.command_qdom |> Fake_system.expect)) in

    (* python-gobject *)
    let root = Q.parse_input None @@ Xmlm.make_input (`String (0, test_gobject_feed)) |> Element.parse_feed in
    let feed = F.parse system root None in

    let impls = distro#get_impls_for_feed ~problem:failwith feed in
    let host_gobject =
      try impls |> StringMap.bindings |> List.find is_host |> snd
      with Not_found -> skip_if true "No host python-gobject found"; assert false in
    let () =
      match host_gobject.props.requires with
      | [ {dep_importance = `Restricts; dep_iface = "http://repo.roscidus.com/python/python"; dep_restrictions = [_]; _ } ] -> ()
      | _ -> assert_failure "No host restriction for host python-gobject" in
    let from_feed = Zeroinstall.Feed_url.format_url (`Distribution_feed feed.F.url) in
    let attrs = host_gobject.props.attrs
      |> Q.AttrMap.add_no_ns "from-feed" from_feed in
    let sel = ZI.make "selection" ~attrs in
    let sels = ZI.make "selections"
      ~attrs:(Q.AttrMap.singleton "interface" "http://repo.roscidus.com/python/python")
      ~child_nodes:[sel] |> Element.parse_selections in
    match Element.selections sels with
    | [sel] -> assert (distro#is_installed_quick sel)
    | _ -> assert false
  );

  "rpm">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if (Sys.os_type = "Win32") "Paths get messed up on Windows";
    let rpmdir = Test_0install.feed_dir +/ "rpm" in
    let old_path = Unix.getenv "PATH" in
    Unix.putenv "PATH" (rpmdir ^ ":" ^ old_path);

    fake_system#set_spawn_handler (Some Fake_system.real_spawn_handler);
    let rpm = Distro_impls.RPM.rpm_distribution ~rpm_db_packages:(rpmdir +/ "Packages") ~packagekit config in

    let get_feed xml = load_feed config.system (Printf.sprintf
      "<?xml version='1.0'?>\n\
      <interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface' uri='http://example.com/yast2-update'>\n\
        <name>yast2</name>\n%s\n\
      </interface>" xml) in

    let feed = get_feed
      "<package-implementation distributions='Debian' package='yast2-mail'/>\n\
       <package-implementation distributions='RPM' package='yast2-update'/>" in
    let impls = to_impl_list @@ rpm#get_impls_for_feed ~problem:failwith feed in
    begin match impls with
    | [yast] ->
        assert_equal "package:rpm:yast2-update:2.15.23-21:i586" (Impl.get_attr_ex "id" yast);
        assert_equal "2.15.23-21" (Impl.get_attr_ex "version" yast);
        assert_equal "*-i586" (Zeroinstall.Arch.format_arch (yast.Impl.os, yast.Impl.machine));
    | _ -> assert false end;

    let feed = get_feed "<package-implementation distributions='RPM' package='yast2-mail'/>\n\
                         <package-implementation distributions='RPM' package='yast2-update'/>" in
    let impls = to_impl_list @@ rpm#get_impls_for_feed ~problem:failwith feed in
    assert_equal 2 (List.length impls);

    let feed = get_feed "<package-implementation distributions='' package='yast2-mail'/>\n\
                         <package-implementation package='yast2-update'/>" in
    let impls = to_impl_list @@ rpm#get_impls_for_feed ~problem:failwith feed in
    assert_equal 2 (List.length impls);

    let feed = get_feed "<package-implementation distributions='Foo Bar Baz' package='yast2-mail'/>" in
    let impls = to_impl_list @@ rpm#get_impls_for_feed ~problem:failwith feed in
    assert_equal 1 (List.length impls);

    (* Check the caching worked *)
    fake_system#set_spawn_handler None;
    let impls = to_impl_list @@ rpm#get_impls_for_feed ~problem:failwith feed in
    assert_equal 1 (List.length impls);

    (* Check escaping works *)
    let feed = get_feed "<package-implementation package='poor=name'/>" in
    let impls = to_impl_list @@ rpm#get_impls_for_feed ~problem:failwith feed in
    assert_equal 1 (List.length impls);

    Unix.putenv "PATH" old_path;
  );

  "debian">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    skip_if (Sys.os_type = "Win32") "Paths get messed up on Windows";
    let packagekit = lazy (Fake_distro.fake_packagekit (`Unavailable "Use apt-cache")) in
    let xml =
      "<?xml version='1.0' ?>\n\
      <interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>\n\
      <name>Foo</name>\n\
      <summary>Foo</summary>\n\
      <description>Foo</description>\n\
      <package-implementation package='gimp'/>\n\
      <package-implementation package='python-bittorrent' foo='bar' main='/usr/bin/pbt'/>\n\
      </interface>" in
    let root = `String (0, xml) |> Xmlm.make_input |> Q.parse_input None |> Element.parse_feed in

    let feed = F.parse config.system root (Some "/local.xml") in

    assert_equal 0 (StringMap.cardinal feed.F.implementations);

    let dpkgdir = Test_0install.feed_dir +/ "dpkg" in
    let old_path = Unix.getenv "PATH" in
    Unix.putenv "PATH" (dpkgdir ^ ":" ^ old_path);
    fake_system#putenv "PATH" (dpkgdir ^ ":" ^ old_path);
    fake_system#set_spawn_handler (Some Fake_system.real_spawn_handler);
    let deb = Distro_impls.Debian.debian_distribution ~status_file:(dpkgdir +/ "status") ~packagekit config |> Distro.of_provider in
    begin match to_impl_list @@ Distro.get_impls_for_feed deb ~problem:failwith feed with
    | [impl] ->
        Fake_system.assert_str_equal "package:deb:python-bittorrent:3.4.2-10-2:*" (Impl.get_attr_ex "id" impl);
        assert_equal ~msg:"Stability" Stability.Packaged impl.Impl.stability;
        assert_equal ~msg:"Requires" [] impl.Impl.props.Impl.requires;
        Fake_system.assert_str_equal "/usr/bin/pbt" (Element.main impl.Impl.qdom |> Fake_system.expect);
        (Element.as_xml impl.Impl.qdom).Q.attrs |> Q.AttrMap.get_no_ns "foo" |> assert_equal (Some "bar");
        Fake_system.assert_str_equal "distribution:/local.xml" (Impl.get_attr_ex "from-feed" impl);
    | _ -> assert false end;

    let get_feed xml = load_feed config.system (Printf.sprintf
      "<?xml version='1.0'?>\n\
      <interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface' uri='http://example.com/bittorrent'>\n\
        <name>dummy</name>\n%s\n\
      </interface>" xml) in

    (* testCommand *)
    let feed = get_feed "<package-implementation main='/unused' package='python-bittorrent'><command path='/bin/sh' name='run'/></package-implementation>" in
    let requirements = Zeroinstall.Requirements.run "http://example.com/bittorrent" in
    let feed_provider =
      object
        inherit Zeroinstall.Feed_provider_impl.feed_provider config deb
        method! get_feed = function
          | (`Remote_feed "http://example.com/bittorrent") as url ->
              let result = Some (feed, F.({ last_checked = None; user_stability = StringMap.empty })) in
              cache <- Zeroinstall.Feed_url.FeedMap.add url result cache;
              result
          | _ -> assert false
      end in
    begin match Zeroinstall.Solver.solve_for config feed_provider requirements with
    | (true, results) ->
        let sels = Zeroinstall.Solver.selections results in
        let sel = Zeroinstall.Selections.(get_selected_ex {iface = "http://example.com/bittorrent"; source = false}) sels in
        let run = Zeroinstall.Element.get_command_ex "run" sel in
        Fake_system.assert_str_equal "/bin/sh" (Zeroinstall.Element.path run |> default "missing")
    | (false, results) -> failwith @@ Zeroinstall.Solver.get_failure_reason config results end;
    Fake_system.fake_log#reset;

    (* Part II *)
    let gimp_feed = get_feed "<package-implementation package='gimp'/>" in
    Distro.get_impls_for_feed deb ~problem:failwith gimp_feed |> assert_equal StringMap.empty;

    (* Initially, we only get information about the installed version... *)
    let bt_feed = get_feed "<package-implementation package='python-bittorrent'>\n\
                                <restricts interface='http://python.org/python'>\n\
                                  <version not-before='3'/>\n\
                                </restricts>\n\
                                </package-implementation>" in
    Distro.get_impls_for_feed deb ~problem:failwith bt_feed |> to_impl_list |> List.length |> assert_equal 1;

    Fake_system.fake_log#reset;

    (* Tell distro to fetch information about candidates... *)
    Lwt_main.run (Distro.check_for_candidates deb ~ui:Fake_system.null_ui bt_feed);

    (* Now we see the uninstalled package *)
    let compare_version a b = compare a.Impl.parsed_version b.Impl.parsed_version in
    begin match to_impl_list @@ Distro.get_impls_for_feed deb ~problem:failwith bt_feed |> List.sort compare_version with
    | [installed; uninstalled] as impls ->
        (* Check restriction appears for both candidates *)
        impls |> List.iter (fun impl ->
          match impl.Impl.props.Impl.requires with
          | [{Impl.dep_iface = "http://python.org/python"; _}] -> ()
          | _ -> assert false
        );
        Fake_system.assert_str_equal "3.4.2-10-2" (Impl.get_attr_ex "version" installed);
        assert_equal true @@ is_available_locally config installed;
        assert_equal false @@ is_available_locally config uninstalled;
        assert_equal None installed.Impl.machine;
    | _ -> assert false
    end;

    let feed = get_feed "<package-implementation package='libxcomposite-dev'/>" in
    begin match to_impl_list @@ Distro.get_impls_for_feed deb ~problem:failwith feed with
    | [libxcomposite] ->
        Fake_system.assert_str_equal "0.3.1-1" @@ Impl.get_attr_ex "version" libxcomposite;
        Fake_system.assert_str_equal "i386" @@ Arch.format_machine_or_star libxcomposite.Impl.machine
    | _ -> assert false
    end;

    (* Java is special... *)
    let feed = get_feed "<package-implementation package='openjdk-7-jre'/>" in
    begin match to_impl_list @@ Distro.get_impls_for_feed deb ~problem:failwith feed with
    | [impl] -> Fake_system.assert_str_equal "7.3-2.1.1-3" @@ Impl.get_attr_ex "version" impl
    | _ -> assert false end;

    (* Check the disk cache works *)
    fake_system#set_spawn_handler None;
    let deb = Distro_impls.Debian.debian_distribution ~status_file:(dpkgdir +/ "status") ~packagekit config |> Distro.of_provider in
    begin match to_impl_list @@ Distro.get_impls_for_feed deb ~problem:failwith feed with
    | [impl] -> Fake_system.assert_str_equal "7.3-2.1.1-3" @@ Impl.get_attr_ex "version" impl
    | _ -> assert false end;

    Unix.putenv "PATH" old_path;
  );

  "import_packages">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let master_uri = "http://example.com/iface" in
    let master_feed = parse_xml
      "<interface uri='http://example.com/iface'><name>master</name><summary>master</summary>\
         <feed src='http://example.com/imported'/>\
      </interface>" in
    let imported_feed = parse_xml
      "<interface uri='http://example.com/imported'><name>imported</name><summary>imported</summary>\
         <package-implementation package='foo'/>\
      </interface>" in
    let distro =
      object (self)
        inherit Distro.distribution config
        val check_host_python = false
        val distro_name = "test"
        val id_prefix = "package:test"

        method private get_package_impls query =
          match query.Distro.package_name with
          | "foo" ->
              self#add_package_implementation
                ~main:"foo"
                ~package_state:`Installed
                ~version:(Version.parse "1")
                ~machine:None
                ~quick_test:None
                ~distro_name
                query
          | _ -> ()

        method check_for_candidates ~ui:_ _feed = Lwt.return ()
      end in
    let feed_provider = new Test_solver.fake_feed_provider config.system (Some distro) in
    feed_provider#add_iface master_feed;
    feed_provider#add_iface imported_feed;
    let scope_filter = { Scope_filter.
      extra_restrictions = StringMap.empty;
      os_ranks = Arch.custom_os_ranking StringMap.empty;
      machine_ranks = Arch.custom_machine_ranking StringMap.empty;
      languages = Support.Locale.LangMap.empty;
      allowed_uses = StringSet.empty;
      may_compile = false;
    } in
    let impl_provider = new Impl_provider.default_impl_provider config (feed_provider :> Feed_provider.feed_provider) scope_filter in
    let impls = impl_provider#get_implementations master_uri ~source:false in
    assert (List.length impls.Impl_provider.impls = 1)
  )
]
