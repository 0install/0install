(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Support.Common
open OUnit
module U = Support.Utils
module R = Zeroinstall.Requirements
module Q = Support.Qdom

module Apps = Zeroinstall.Apps

let expect = function
  | Some x -> x
  | None -> assert_failure "got None!"

let suite = "apps">::: [
  "simple">:: Fake_system.with_tmpdir (fun tmpdir ->
    let url = "http://example.com:8000/Hello.xml" in
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in

    fake_system#add_file "/lib/ld-linux.so.2" "/";    (* Enable multi-arch *)

    let interface_cache = tmpdir +/ "cache/0install.net/interfaces" in
    U.makedirs system interface_cache 0o755;
    U.copy_file system
      "../../tests/Hello.xml"
      (interface_cache +/ "http%3a%2f%2fexample.com%3a8000%2fHello.xml")
      0o644;

    let r = R.default_requirements url in
    let () =
      try ignore @@ Apps.create_app config "/foo" r; assert false
      with Safe_exception _ -> () in

    ignore @@ Apps.create_app config "hello" r;

    let app = expect @@ Apps.lookup_app config "hello" in
    Fake_system.assert_str_equal url (Apps.get_requirements system app).R.interface_uri;

    ignore @@ Support.Basedir.save_path system
      ("0install.net" +/ "implementations" +/ "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a")
      config.basedirs.Support.Basedir.cache;

    let slave = new Zeroinstall.Python.slave config in

    (* Initialise the new app with selections for version 0.1-pre *)
    let distro = new Zeroinstall.Distro.generic_distribution slave in
    let feed_provider = new Zeroinstall.Feed_cache.feed_provider config distro in
    let () =
      match Zeroinstall.Solver.solve_for config feed_provider r with
      | (true, results) ->
          let sels = results#get_selections () in
          let sel = List.hd sels.Q.child_nodes in
          Q.set_attribute "version" "0.1-pre" sel;
          Apps.set_selections config app sels ~touch_last_checked:true
      | _ -> assert_failure "Solve failed" in

    (* Get selections without updating. *)
    let sels = Apps.get_selections_no_updates config app in
    Fake_system.assert_str_equal url @@ ZI.get_attribute "interface" sels;
    Fake_system.assert_str_equal "0.1-pre" @@ ZI.get_attribute "version" (List.hd sels.Q.child_nodes);

    let slave = new Zeroinstall.Python.slave config in

    (* Get selections with updates allowed; should resolve and find version 1. *)
    let sels = Apps.get_selections_may_update config distro slave ~use_gui:No app in
    Fake_system.assert_str_equal url @@ ZI.get_attribute "interface" sels;
    Fake_system.assert_str_equal "1" @@ ZI.get_attribute "version" (List.hd sels.Q.child_nodes);
  )
]
