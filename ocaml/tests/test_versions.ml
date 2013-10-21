(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit
open Support.Common
open Fake_system
module Versions = Zeroinstall.Versions
module F = Zeroinstall.Feed

let pv v =
  let parsed = Versions.parse_version v in
  assert_str_equal v @@ Versions.format_version parsed;
  parsed

let invalid v =
  try ignore @@ pv v; assert false
  with Safe_exception _ -> () 

let assert_order a b =
  assert ((pv a) < (pv b))

let suite = "versions">::: [
  "versions">:: (fun () ->
    assert_order "0.9" "1.0";
    assert_order "1" "1.0";
    assert ((pv "1.0") = (pv "1.0"));
    assert_order "0.9.9" "1.0";
    assert_order "2" "10";

    invalid ".";
    invalid "hello";
    invalid "2./1";
    invalid ".1";
    invalid "";

    assert_order "1.0" "1.0-0";
    assert_order "1.0-0" "1.0-1";
    assert_order "1.0-0" "1.0-1";

    assert_order "1.0-pre1" "1.0-pre99";
    assert_order "1.0-pre99" "1.0-rc1";
    assert_order "1.0-rc1" "1.0";
    assert_order "1.0" "1.0-0";
    assert_order "1.0-0" "1.0-post";
    assert_order "2.1.9-pre" "2.1.9-pre-1";

    assert_order "2-post999" "3-pre1";
  );

  "ranges">:: (fun () ->
    let v1 = Versions.parse_version "1" in
    let v1_1 = Versions.parse_version "1.1" in
    let v2 = Versions.parse_version "2" in

    let parse expr =
      let test = Versions.parse_expr expr in
      assert (test Versions.dummy);
      test in

    let t = parse "..!" in
    assert (t v1);
    assert (t v1_1);
    assert (t v2);

    let t = parse "1.1.." in
    assert (not (t v1));
    assert (t v1_1);
    assert (t v2);

    let t = parse "1.1" in
    assert (not (t v1));
    assert (t v1_1);
    assert (not (t v2));

    let t = parse "!1.1" in
    assert (t v1);
    assert (not (t v1_1));
    assert (t v2);

    let t = parse "..!2" in
    assert (t v1);
    assert (t v1_1);
    assert (not (t v2));

    let t = parse "1.1..!2" in
    assert (not (t v1));
    assert (t v1_1);
    assert (not (t v2));

    let t = parse "1..!1.1 | 2" in
    assert (t v1);
    assert (not (t v1_1));
    assert (t v2);

    try
      ignore @@ Versions.parse_expr "1.1..2";
      assert false
    with Safe_exception _ -> ()
  );

  "ranges2">:: (fun () ->
    let r = ref (F.make_version_restriction "2.6..!3 | 3.2.2.. | 1 | ..!0.2") in

    let test v result =
      let impl = {Zeroinstall.Solver.dummy_impl with F.parsed_version = Versions.parse_version v} in
      assert_equal result @@ (!r)#meets_restriction impl in

    test "0.1"  true;
    test "0.2"  false;
    test "0.3"  false;
    test "1"    true;
    test "2.5"  false;
    test "2.6"  true;
    test "2.7"  true;
    test "3-pre" true;
    test "3"    false;
    test "3.1"  false;
    test "3.2.1" false;
    test "3.2.2" true;
    test "3.3"  true;

    r := F.make_version_restriction "!7";
    test "1" true;
    test "7" false;
    test "8" true;

    let fail expr msg =
      Fake_system.assert_raises_safe msg (lazy (
        ignore @@ Versions.parse_expr expr
      )) in

    fail "1..2" "End of range must be exclusive (use '..!2', not '..2')";
    fail ".2" "Cannot parse '' as a 64-bit integer (in '.2')";
    fail "0.2-hi" "Invalid version modifier '-hi'";
  );

  "cleanup_distro_version">:: (fun () ->
    let check expected messy =
      match Versions.try_cleanup_distro_version messy with
      | None -> failwith messy
      | Some clean -> assert_str_equal expected clean in

    check "0.3.1-1" "1:0.3.1-1";
    check "0.3.1-1" "0.3.1-1ubuntu0";
    check "0.3-post1-rc2" "0.3-post1-rc2";
    check "0.3.1-2" "0.3.1-r2-r3";
    check "6.17" "6b17";
    check "20-1" "b20_1";
    check "17" "p17";
    check "7-pre3-2.1.1-3" "7~u3-2.1.1-3";	(* Debian snapshot *)
    check "7-pre3-2.1.1-pre1-1" "7~u3-2.1.1~pre1-1ubuntu2";

    assert_equal None (Versions.try_cleanup_distro_version "cvs");
  );

  "restrictions">:: (fun () ->
    let v6 = {Zeroinstall.Solver.dummy_impl with
      F.parsed_version = (Versions.parse_version "6");
      F.impl_type = F.PackageImpl {F.package_distro = "RPM"; F.package_installed = true; F.retrieval_method = None};
    } in
    let v7 = {Zeroinstall.Solver.dummy_impl with
      F.parsed_version = (Versions.parse_version "7");
      F.impl_type = F.PackageImpl {F.package_distro = "Gentoo"; F.package_installed = true; F.retrieval_method = None};
    } in

    let r = F.make_version_restriction "!7" in
    Fake_system.assert_str_equal "version !7" r#to_string;
    assert (r#meets_restriction v6);
    assert (not (r#meets_restriction v7));

    let r = F.make_distribtion_restriction "RPM Debian" in
    Fake_system.assert_str_equal "distribution:RPM Debian" r#to_string;
    assert (r#meets_restriction v6);
    assert (not (r#meets_restriction v7));
  );
]
