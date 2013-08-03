(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit
open Support.Common
open Fake_system

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

    let t = Versions.parse_expr "..!" in
    assert (t v1);
    assert (t v1_1);
    assert (t v2);

    let t = Versions.parse_expr "1.1.." in
    assert (not (t v1));
    assert (t v1_1);
    assert (t v2);

    let t = Versions.parse_expr "1.1" in
    assert (not (t v1));
    assert (t v1_1);
    assert (not (t v2));

    let t = Versions.parse_expr "!1.1" in
    assert (t v1);
    assert (not (t v1_1));
    assert (t v2);

    let t = Versions.parse_expr "..!2" in
    assert (t v1);
    assert (t v1_1);
    assert (not (t v2));

    let t = Versions.parse_expr "1.1..!2" in
    assert (not (t v1));
    assert (t v1_1);
    assert (not (t v2));

    let t = Versions.parse_expr "1..!1.1 | 2" in
    assert (t v1);
    assert (not (t v1_1));
    assert (t v2);

    try
      ignore @@ Versions.parse_expr "1.1..2";
      assert false
    with Safe_exception _ -> ()
  );
]
