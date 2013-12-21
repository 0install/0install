(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit

let () = ignore on_windows

module Q = Support.Qdom

let assert_str_equal = Fake_system.assert_str_equal

let parse s = `String (0, s) |> Xmlm.make_input |> Q.parse_input None

let suite = "qdom">::: [
  "simple">:: (fun () ->
    let root = parse "<?xml version=\"1.0\"?><root/>" in
    assert_equal ("", "root") root.Q.tag;
    assert_str_equal "" root.Q.last_text_inside;
  );

  "text">:: (fun () ->
    let root = parse "<?xml version=\"1.0\"?><root> Hi </root>" in
    assert_equal ("", "root") root.Q.tag;
    assert_str_equal " Hi " root.Q.last_text_inside;
    assert_equal [] root.Q.child_nodes;

    let root = parse "<?xml version='1.0'?><root>A <b>bold</b> move.</root>" in
    assert_str_equal " move." root.Q.last_text_inside;
    assert (Str.string_match (Str.regexp "^<\\?xml .*\\?>\n<root>A <b>bold</b> move.</root>") (Q.to_utf8 root) 0);
  );

  "ns">:: (fun () ->
    let root = parse "<?xml version='1.0'?><x:root xmlns:x='http://myns.com/foo'/>" in
    assert_equal ("http://myns.com/foo", "root") root.Q.tag;
    assert_str_equal "" root.Q.last_text_inside;
    assert_equal [] root.Q.child_nodes;
  );

  "attrs">:: (fun () ->
    let root = parse "<?xml version='1.0'?><root x:foo='bar' bar='baz' xmlns:x='http://myns.com/foo'/>" in
    match root.Q.attrs with
    | [(("http://myns.com/foo", "foo"), "bar"); (("", "bar"), "baz")] -> ()
    | _ -> assert false
  );

  "nested">:: (fun () ->
    let root = parse "<?xml version='1.0'?><root><name>Bob</name><age>3</age></root>" in
    assert_equal ("", "root") root.Q.tag;
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
