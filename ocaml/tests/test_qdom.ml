(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
open OUnit

module Q = Support.Qdom

let assert_str_equal = Fake_system.assert_str_equal

let parse_simple s = `String (0, s) |> Xmlm.make_input |> Q.parse_input None

let parse s1 =
  let xml1 = parse_simple s1 in
  let s2 = Q.to_utf8 xml1 in
  let xml2 = parse_simple s2 in
  if Q.compare_nodes ~ignore_whitespace:false xml1 xml2 <> 0 then
    Safe_exn.failf "XML changed after saving and reloading!\n%s\n%s" s1 s2;
  Fake_system.assert_str_equal s2 (Q.to_utf8 xml2);
  xml1

let suite = "qdom">::: [
  "simple">:: (fun () ->
    let root = parse "<?xml version=\"1.0\"?><root/>" in
    Q.Empty.check_tag "root" root;
    assert_equal (Some "root") (Q.Empty.tag root);
    assert_str_equal "" (Q.simple_content root);
  );

  "text">:: (fun () ->
    let root = parse "<?xml version=\"1.0\"?><root> Hi </root>" in
    assert_str_equal " Hi " root.Q.last_text_inside;
    assert_equal [] root.Q.child_nodes;

    let root = parse "<?xml version='1.0'?><root>A <b>bold</b> move.</root>" in
    assert_str_equal " move." root.Q.last_text_inside;
    assert (Str.string_match (Str.regexp "^<\\?xml .*\\?>\n<root>A <b>bold</b> move.</root>") (Q.to_utf8 root) 0);
  );

  "ns">:: (fun () ->
    let root = parse "<?xml version='1.0'?><x:root xmlns:x='http://myns.com/foo'/>" in
    assert_equal ("http://myns.com/foo", "root") root.Q.tag;
    assert_str_equal "" (Q.simple_content root);
    assert_equal [] root.Q.child_nodes;

    let root = parse "<?xml version='1.0'?><x:root xmlns:x='http://myns.com/foo' x:y='foo'/>" in
    assert_equal ("http://myns.com/foo", "root") root.Q.tag;
    assert_equal "foo" (Q.AttrMap.get ("http://myns.com/foo", "y") root.Q.attrs |> Fake_system.expect);

    (* Add a default-ns node to a non-default document *)
    let other = parse "<imported xmlns='http://other/'/>" in
    let combined = {root with Q.child_nodes = [other]} |> Q.to_utf8 |> parse in
    assert_equal ("http://myns.com/foo", "root") combined.Q.tag;
    assert_equal ("http://other/", "imported") (List.hd combined.Q.child_nodes).Q.tag;

    (* Add a default-ns node to a default-ns document *)
    let root = parse "<root xmlns='http://original/'/>" in
    let other = parse "<imported xmlns='http://other/'/>" in
    let combined = {root with Q.child_nodes = [other]} |> Q.to_utf8 |> parse in
    assert_equal ("http://original/", "root") combined.Q.tag;
    assert_equal ("http://other/", "imported") (List.hd combined.Q.child_nodes).Q.tag;
  );

  "attrs">:: (fun () ->
    let root = parse "<?xml version='1.0'?><root x:foo='bar' bar='baz' xmlns:x='http://myns.com/foo'/>" in
    root.Q.attrs |> Q.AttrMap.get ("http://myns.com/foo", "foo") |> assert_equal (Some "bar");
    root.Q.attrs |> Q.AttrMap.get ("", "bar") |> assert_equal (Some "baz");
  );

  "nested">:: (fun () ->
    let root = parse "<?xml version='1.0'?><root><name>Bob</name><age>3</age></root>" in
    assert_str_equal "" root.Q.last_text_inside;

    let open Q in
    match root.child_nodes with
    | [
        { tag = ("", "name"); last_text_inside = "Bob"; child_nodes = []; _ };
        { tag = ("", "age"); last_text_inside = "3"; child_nodes = []; _ };
      ] -> ()
    | _ -> assert false
  );
]
