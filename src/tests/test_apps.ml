(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Support
open Support.Common
open OUnit
module U = Support.Utils
module R = Zeroinstall.Requirements
module Q = Support.Qdom

module Apps = Zeroinstall.Apps

let suite = "apps">::: [
  "simple">:: Fake_system.with_tmpdir (fun tmpdir ->
    let url = "http://example.com:8000/Hello.xml" in
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in

    fake_system#add_file "/lib/ld-linux.so.2" "/";    (* Enable multi-arch *)

    let interface_cache = tmpdir +/ "cache/interfaces" in
    U.makedirs system interface_cache 0o755;
    U.copy_file system
      (Fake_system.test_data "Hello.xml")
      (interface_cache +/ "http%3a%2f%2fexample.com%3a8000%2fHello.xml")
      0o644;

    let r = R.run url in
    let () =
      try ignore @@ Apps.create_app config "/foo" r; assert false
      with Safe_exn.T _ -> () in

    ignore @@ Apps.create_app config "hello" r;

    let app = Fake_system.expect @@ Apps.lookup_app config "hello" in
    Fake_system.assert_str_equal url (Apps.get_requirements system app).R.interface_uri;

    let impl_dir = Zeroinstall.Paths.Cache.(save_path implementations) config.paths in
    U.makedirs system (impl_dir +/ "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a") 0o755;

    (* Initialise the new app with selections for version 0.1-pre *)
    let distro = Fake_distro.make config in
    let feed_provider = new Zeroinstall.Feed_provider_impl.feed_provider config distro in
    let () =
      match Zeroinstall.Solver.solve_for config feed_provider r with
      | (true, results) ->
          let sels = Zeroinstall.Solver.selections results |> Zeroinstall.Selections.as_xml in
          {sels with
            Q.child_nodes = sels.Q.child_nodes |> List.map (fun child ->
              {child with Q.attrs = child.Q.attrs |> Q.AttrMap.add_no_ns "version" "0.1-pre"}
            )
          }
          |> Zeroinstall.Selections.create
          |> Apps.set_selections config app ~touch_last_checked:true
      | _ -> assert_failure "Solve failed" in

    (* Get selections without updating. *)
    let sels = Apps.get_selections_no_updates system app |> Zeroinstall.Selections.as_xml in
    Fake_system.assert_str_equal url @@ ZI.get_attribute "interface" sels;
    Fake_system.assert_str_equal "0.1-pre" @@ ZI.get_attribute "version" (List.hd sels.Q.child_nodes);

    let tools = Fake_system.make_tools config in

    (* Get selections with updates allowed; should resolve and find version 1. *)
    let sels = Apps.get_selections_may_update tools app |> Lwt_main.run |> Zeroinstall.Selections.as_xml in
    Fake_system.assert_str_equal url @@ ZI.get_attribute "interface" sels;
    Fake_system.assert_str_equal "1" @@ ZI.get_attribute "version" (List.hd sels.Q.child_nodes);
  )
]
