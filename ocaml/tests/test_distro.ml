(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Support.Common
open OUnit
module Qdom = Support.Qdom
open Fake_system
module Distro = Zeroinstall.Distro
module Feed = Zeroinstall.Feed
module U = Support.Utils

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

let suite = "distro">::: [
  "arch">:: Fake_system.with_tmpdir (fun tmpdir ->
    skip_if (Sys.os_type = "Win32") "Paths get messed up on Windows";

    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    fake_system#add_file "/var/lib/pacman/local/python2-2.7.2-4/desc" "../../tests/arch/local/python2-2.7.2-4/desc";
    fake_system#add_dir "/usr/bin" [];
    fake_system#add_dir "/bin" ["python2"; "python3"];
    let system = (fake_system :> system) in
    let distro = new Distro.ArchLinux.arch_distribution config in
    let root = Qdom.parse_input None @@ Xmlm.make_input (`String (0, test_feed)) in
    let feed = Feed.parse system root None in
    let impls = Distro.get_package_impls distro feed in
    let open Feed in
    match impls with
    | Some [impl] ->
        assert_str_equal "2.7.2-4" (Zeroinstall.Versions.format_version impl.parsed_version);
        let run = StringMap.find "run" impl.props.commands in
        assert_str_equal "/bin/python2" (ZI.get_attribute "path" run.command_qdom)
    | Some impls -> assert_failure @@ Printf.sprintf "want 1 Python, got %d" (List.length impls)
    | None -> assert_failure "didn't check distro!"
  );

  "test_host_python">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in

    let my_spawn_handler args cin cout cerr =
      Fake_system.real_system#create_process args cin cout cerr in
    fake_system#set_spawn_handler (Some my_spawn_handler);

    let slave = new Zeroinstall.Python.slave config in
    let distro = new Distro.generic_distribution slave in

    let open Feed in
    let is_host impl = U.starts_with (get_attr "id" impl) "package:host:" in
    let find_host impls =
      try List.find is_host impls
      with Not_found -> assert_failure "No host package found!" in

    let root = Qdom.parse_input None @@ Xmlm.make_input (`String (0, test_feed)) in
    let feed = parse system root None in
    let () =
      match Distro.get_package_impls distro feed with
      | None -> assert_failure "Didn't check!"
      | Some impls ->
          let host_python = find_host impls in
          let python_run =
            try StringMap.find "run" host_python.props.commands
            with Not_found -> assert_failure "No run command for host Python" in
          assert (Fake_system.real_system#file_exists (ZI.get_attribute "path" python_run.command_qdom)) in

    (* python-gobject *)
    let root = Qdom.parse_input None @@ Xmlm.make_input (`String (0, test_gobject_feed)) in
    let feed = Feed.parse system root None in
    let () =
      match Distro.get_package_impls distro feed with
      | None -> assert_failure "Didn't check!"
      | Some impls ->
          let open Feed in
          let host_gobject = find_host impls in
          let () =
            match host_gobject.props.requires with
            | [ {dep_importance = Dep_restricts; dep_iface = "http://repo.roscidus.com/python/python"; dep_restrictions = [_]; _ } ] -> ()
            | _ -> assert_failure "No host restriction for host python-gobject" in
          let sel = ZI.make host_gobject.qdom.Qdom.doc "selection" in
          sel.Qdom.attrs <- AttrMap.bindings host_gobject.props.attrs;
          Qdom.set_attribute "from-feed" ("distribution:" ^ feed.url) sel;
          assert (distro#is_installed sel) in
    slave#close;
  );
]
