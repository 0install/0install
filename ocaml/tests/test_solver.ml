(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit

module ZI = General.ZI

module StringData =
  struct
    type t = string
    let to_string s = s
    let unused = "unused"
  end

module Sat = Sat.MakeSAT(StringData)

open Sat

module EString =
struct
  type t = string
  let compare = compare
  let pp_printer = Format.pp_print_string
  let pp_print_sep = OUnitDiff.pp_comma_separator
end

module ListString = OUnitDiff.ListSimpleMake(EString);;

let set_of_attrs elem : string list =
  let str_list = ListLabels.map elem.Support.Qdom.attrs ~f:(fun ((ns, name), value) ->
    if ns <> "" then
      Printf.sprintf "{%s}%s=%s" ns name value
    else
      Printf.sprintf "%s=%s" name value
  ) in
  List.sort compare str_list

let string_of_element elem =
  let buf = Buffer.create 100 in
  let out = Xmlm.make_output @@ `Buffer buf in
  Support.Qdom.output out elem;
  Buffer.contents buf

let xml_diff exp actual =
  let open Support.Qdom in
  let p = Printf.printf in
  let rec find_diff a b =
    if snd a.tag <> snd b.tag then (
      p "Tag <%s> vs <%s>\n" (snd a.tag) (snd b.tag); true
    ) else if a.tag <> b.tag then (
      p "Namespace '%s' vs '%s'\n" (fst a.tag) (fst a.tag); true
    ) else (
      assert_equal ~printer:(fun s -> s) (trim a.text_before) (trim b.text_before);
      assert_equal ~printer:(fun s -> s) (trim a.last_text_inside) (trim b.last_text_inside);
      ListString.assert_equal (set_of_attrs a) (set_of_attrs b);
      if List.length a.child_nodes <> List.length b.child_nodes then (
        p "Number of child nodes differs\n"; true
      ) else (
        List.exists2 find_diff a.child_nodes b.child_nodes
      )
    ) in
  if find_diff exp actual then (
    assert_equal ~printer:(fun s -> s)
      (string_of_element exp)
      (string_of_element actual)
  )


(** Parse a test-case in solves.xml *)
let make_solver_test test_elem =
  ZI.check_tag "test" test_elem;
  let name = ZI.get_attribute "name" test_elem in
  name >:: (fun () ->
    let reqs = ref (Requirements.default_requirements "") in
    let ifaces = Hashtbl.create 10 in
    let fails = ref false in
    let add_iface elem =
      let open Feed in
      let uri = ZI.get_attribute "uri" elem in
      let feed = parse elem None in
      let impls = get_implementations feed in
      let impls = List.sort (fun a b -> compare b.parsed_version a.parsed_version) impls in
      Hashtbl.add ifaces uri impls in
    let expected_selections = ref (ZI.make_root "missing") in
    let process child = match ZI.tag child with
    | Some "interface" -> add_iface child
    | Some "requirements" ->
        reqs := {!reqs with Requirements.interface_uri = ZI.get_attribute "interface" child};
        fails := ZI.get_attribute_opt "fails" child = Some "true"
    | Some "selections" -> expected_selections := child
    | _ -> failwith "Unexpected element" in
    ZI.iter ~f:process test_elem;

    let impl_provider =
      object
        method get_implementations iface =
          try Hashtbl.find ifaces iface
          with Not_found -> []
      end in
    let solver = new Solver.sat_solver impl_provider in
    let (ready, result) = solver#solve !reqs in
    assert (ready = (not !fails));
    let actual_sels = result#get_selections () in
    assert (ZI.tag actual_sels = Some "selections");
    if ready then (
      let changed = Whatchanged.show_changes Fake_system.real_system !expected_selections actual_sels in
      assert (not changed);
    );
    xml_diff !expected_selections actual_sels
  )

let suite = "solver">::: [
  "sat_simple">:: (fun () ->
    let problem = create () in

    let p1 = add_variable problem "p1" in
    let p2 = add_variable problem "p2" in

    let lib1 = add_variable problem "lib1" in
    let lib2 = add_variable problem "lib2" in

    let decider () = Some p1 in

    ignore @@ at_most_one problem [p1; p2];
    ignore @@ at_most_one problem [lib1; lib2];

    at_least_one problem [neg p1; lib1];
    at_least_one problem [neg p2; lib2];

    match run_solver problem decider with
    | None -> assert false
    | Some solution ->
        assert (solution p1 = true);
        assert (solution p2 = false);

        assert (solution lib1 = true);
        assert (solution lib2 = false)
  );

  "sat_analyse">:: (fun () ->
    let problem = create () in

    let p1 = add_variable problem "p1" in
    let p2 = add_variable problem "p2" in

    let lib1 = add_variable problem "lib1" in
    let lib2 = add_variable problem "lib2" in

    let conf1 = add_variable problem "conf1" in

    let decider () = Some p1 in

    at_least_one problem [p1; p2];
    ignore @@ at_most_one problem [p1; p2];
    ignore @@ at_most_one problem [lib1; lib2];

    (* p1 requires lib1 or lib2 *)
    at_least_one problem [neg p1; lib1; lib2];
    at_least_one problem [neg p2; lib1];

    (* p1 requires conf1, which conflicts with lib1 and lib2 *)
    at_least_one problem [neg p1; conf1];
    at_least_one problem [neg conf1; neg lib1];
    at_least_one problem [neg conf1; neg lib2];

    (* We try p1 first. That requires (lib1 or lib2) and conf1.
      conf1 conflicts with lib, causing us to analyse the problem
      and backtrack. *)

    match run_solver problem decider with
    | None -> assert false
    | Some solution ->
        assert (solution p1 = false);
        assert (solution p2 = true);

        assert (solution lib1 = true);
        assert (solution lib2 = false);
  );

  "sat_at_most">:: (fun () ->
    let problem = create () in

    let p1 = add_variable problem "p1" in
    let p2 = add_variable problem "p2" in

    ignore @@ at_most_one problem [neg p1; neg p2];

    let decider () = Some (neg p1) in
    match run_solver problem decider with
    | None -> assert false
    | Some solution ->
        assert (solution p1 = false);
        assert (solution p2 = true);
  );

  "solver">:::
    try
      let root = Support.Qdom.parse_file Fake_system.real_system "solves.xml" in
      List.map make_solver_test root.Support.Qdom.child_nodes
    with Safe_exception _ as ex ->
      match Support.Utils.safe_to_string ex with
      | Some msg -> failwith msg
      | None -> assert false
]
