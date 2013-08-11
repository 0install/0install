(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
module Qdom = Support.Qdom
open Fake_system

let test_feed = "<?xml version='1.0'?>\n\
<interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface' uri='http://example.com/python'>\n\
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

let suite = "distro">::: [
  "arch">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    fake_system#add_dir "/var/lib/pacman" ["local"];
    fake_system#add_dir "/var/lib/pacman/local" ["python2-2.7.2-4"];
    fake_system#add_file "/var/lib/pacman/local/python2-2.7.2-4/desc" "../../tests/arch/local/python2-2.7.2-4/desc";
    let system = (fake_system :> system) in
    let distro = new Distro.ArchLinux.arch_distribution config in
    let root = Qdom.parse_input None @@ Xmlm.make_input (`String (0, test_feed)) in
    let feed = Feed.parse system root None in
    let impls = Distro.get_package_impls distro feed in
    let open Feed in
    match impls with
    | [impl] -> assert_str_equal "2.7.2-4" (Versions.format_version impl.parsed_version)
    | _ -> assert_failure "want 1 Python"
  );
]
