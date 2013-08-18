(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Support.Common
open OUnit
module U = Support.Utils
module R = Zeroinstall.Requirements

module Apps = Zeroinstall.Apps

let expect = function
  | Some x -> x
  | None -> assert_failure "got None!"

let suite = "apps">::: [
  "solver">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in

    let r = R.default_requirements "http://example.com/env" in
    let () =
      try ignore @@ Apps.create_app config "/foo" r; assert false
      with Safe_exception _ -> () in

    ignore @@ Apps.create_app config "hello" r;

    let app = expect @@ Apps.lookup_app config "hello" in
    U.copy_file system "test_selections.xml" (app +/ "selections.xml") 0o700;

    Fake_system.assert_str_equal "http://example.com/env" (Apps.get_requirements system app).R.interface_uri;

    let sels = Apps.get_selections_no_updates config app in
    Fake_system.assert_str_equal "http://example.com/env" @@ ZI.get_attribute "interface" sels
  )
]
