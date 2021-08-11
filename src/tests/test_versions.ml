(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit
open Zeroinstall
open Support
open Fake_system

let pv v =
  let parsed = Version.parse v in
  assert_str_equal v @@ Version.to_string parsed;
  parsed

let invalid v =
  try ignore @@ pv v; assert false
  with Safe_exn.T _ -> () 

let dummy_impl = Impl.({
  qdom = Element.make_impl Support.Qdom.AttrMap.empty;
  os = None;
  machine = None;
  stability = Stability.Testing;
  props = {
    attrs = Support.Qdom.AttrMap.empty;
    requires = [];
    commands = XString.Map.empty;   (* (not used; we can provide any command) *)
    bindings = [];
  };
  parsed_version = Version.parse "0";
  impl_type = `Local_impl "/dummy";
})

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

    begin
      let open Version in
      assert_equal [([1L], Dash)] @@ pv "1";
      assert_equal [([1L; 0L], Dash)] @@ pv("1.0");
      assert_equal [([1L; 0L], Pre); ([5L], Dash)] @@ pv("1.0-pre5");
      assert_equal [([1L; 0L], Rc); ([5L], Dash)] @@ pv("1.0-rc5");
      assert_equal [([1L; 0L], Dash); ([5L], Dash)] @@ pv("1.0-5");
      assert_equal [([1L; 0L], Post); ([5L], Dash)] @@ pv("1.0-post5");
      assert_equal [([1L; 0L], Post)] @@ pv("1.0-post");
      assert_equal [([1L], Rc); ([2L; 0L], Pre); ([2L], Post)] @@ pv("1-rc2.0-pre2-post");
      assert_equal [([1L], Rc); ([2L; 0L], Pre); ([], Post)] @@ pv("1-rc2.0-pre-post");
    end;

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
    let v1 = Version.parse "1" in
    let v1_1 = Version.parse "1.1" in
    let v2 = Version.parse "2" in

    let parse expr = Version.parse_expr expr in

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
      ignore (Version.parse_expr "1.1..2" : Version.version_expr);
      assert false
    with Safe_exn.T _ -> ()
  );

  "ranges2">:: (fun () ->
    let r = ref (Impl.make_version_restriction "2.6..!3 | 3.2.2.. | 1 | ..!0.2") in

    let test v result =
      let impl = {dummy_impl with Impl.parsed_version = Version.parse v} in
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

    r := Impl.make_version_restriction "!7";
    test "1" true;
    test "7" false;
    test "8" true;

    let fail expr msg =
      Fake_system.assert_raises_safe msg (lazy (
        ignore (Version.parse_expr expr : Version.version_expr)
      )) in

    fail "1..2" "End of range must be exclusive (use '..!2', not '..2')";
    fail ".2" "Cannot parse '' as a 64-bit integer (in '.2')";
    fail "0.2-hi" "Invalid version modifier '-hi'";
  );

  "cleanup_distro_version">:: (fun () ->
    let check expected messy =
      match Version.try_cleanup_distro_version messy with
      | None -> failwith messy
      | Some clean -> assert_str_equal expected (Version.to_string clean) in

    check "0.3.1-1" "1:0.3.1-1";
    check "0.3.1-1-0" "0.3.1-1ubuntu0";
    check "0.3-post1-rc2" "0.3-post1-rc2";
    check "0.3.1-2-3" "0.3.1-r2-r3";
    check "6.17" "6b17";
    check "20-1" "b20_1";
    check "17" "p17";
    check "93-28.2.2" "93u-28.2.2";
    check "7-pre3-2.1.1-3" "7~u3-2.1.1-3";	(* Debian snapshot *)
    check "7-pre3-2.1.1-pre1-1-2" "7~u3-2.1.1~pre1-1ubuntu2";
    check "0.6.0.9999999999999999" "0.6.0.1206569328141510525648634803928199668821045408958";

    assert_equal None (Version.try_cleanup_distro_version "cvs");
  );

  "restrictions">:: (fun () ->
    let v6 = {dummy_impl with
      Impl.parsed_version = (Version.parse "6");
      Impl.impl_type = `Package_impl {Impl.package_distro = "RPM"; Impl.package_state = `Installed};
    } in
    let v7 = {dummy_impl with
      Impl.parsed_version = (Version.parse "7");
      Impl.impl_type = `Package_impl {Impl.package_distro = "Gentoo"; Impl.package_state = `Installed};
    } in

    let r = Impl.make_version_restriction "!7" in
    Fake_system.assert_str_equal "version !7" r#to_string;
    assert (r#meets_restriction v6);
    assert (not (r#meets_restriction v7));

    let r = Impl.make_distribtion_restriction "RPM Debian" in
    Fake_system.assert_str_equal "distribution:RPM Debian" r#to_string;
    assert (r#meets_restriction v6);
    assert (not (r#meets_restriction v7));
  );
]
