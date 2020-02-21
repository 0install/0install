(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
open OUnit
open Zeroinstall

module I = Impl_provider
module U = Support.Utils
module Q = Support.Qdom

module StringData =
  struct
    type t = string
    let pp = Format.pp_print_string
    let unused = "unused"
  end

module S = Zeroinstall_solver.Sat.Make(StringData)

let re_comma = Str.regexp_string ","

class impl_provider =
  let dummy_element = Element.make_impl Q.AttrMap.empty in

  let make_impl arch v =
    let (os, machine) = Arch.parse_arch arch in
    Impl.({
      qdom = dummy_element;
      props = {
        attrs = Q.AttrMap.empty |> Q.AttrMap.add_no_ns "version" v;
        requires = [];
        bindings = [];
        commands = XString.Map.empty;
      };
      stability = Stability.Stable;
      os; machine;
      parsed_version = Version.parse v;
      impl_type = `Local_impl "/"
    }) in

  object (_ : #I.impl_provider)
    val interfaces = Hashtbl.create 10

    method add_impls (name_arch:string) (versions:string list) =
      let (prog, arch) =
        if String.contains name_arch ' ' then
          XString.(split_pair_safe re_space) name_arch
        else
          (name_arch, "*-*") in
      let impls = List.map (make_impl arch) versions in
      let comp_impl a b = Impl.(compare b.parsed_version a.parsed_version) in
      Hashtbl.replace interfaces prog (List.sort comp_impl impls)

    method get_impls name =
      try Hashtbl.find interfaces name
      with Not_found -> failwith name
    method set_impls name impls = Hashtbl.replace interfaces name impls

    method get_implementations iface ~source:_ = { I.
      replacement = None;
      rejects = [];
      compare = (fun _ _ -> failwith "compare");
      feed_problems = [];
      impls =
        try Hashtbl.find interfaces iface
        with Not_found -> failwith iface;
    }

    method is_dep_needed _dep = true
    method extra_restrictions = XString.Map.empty
  end

let re_dep = Str.regexp "\\([a-z]+\\)\\[\\([0-9]+\\)\\(,[0-9]+\\)?\\] => \\([a-z]+\\) \\([0-9]+\\) \\([0-9]+\\)"

let run_sat_test expected problem =
  let parse_id id =
    XString.(split_pair_safe re_dash) (String.trim id) in
  let expected_items = List.map parse_id @@ Str.split re_comma expected in
  let (_root_iface, root_expected_version) = List.hd expected_items in

  let impl_provider = new impl_provider in

  ListLabels.iter problem ~f:(fun line ->
    if String.contains line ':' then (
      let (prog, versions) = XString.(split_pair_safe re_colon) line in
      impl_provider#add_impls (String.trim prog) (Str.split XString.re_space versions)
    ) else (
      if Str.string_match re_dep line 0 then (
        let prog = Str.matched_group 1 line in
        let min_p = Str.matched_group 2 line in
        let max_p =
          try XString.tail (Str.matched_group 3 line) 1
          with Not_found -> min_p in
        let lib = Str.matched_group 4 line in
        let min_v = Str.matched_group 5 line in
        let max_v = Str.matched_group 6 line in

        let min_p = Version.parse min_p in
        let max_p = Version.parse max_p in

        let min_v = Version.parse min_v in
        let max_v = Version.parse max_v in

        let restriction =
          object
            method to_string = line
            method meets_restriction impl =
              impl.Impl.parsed_version >= min_v && impl.Impl.parsed_version <= max_v
          end in
        let dep = Impl.({
          dep_qdom = Element.dummy_restricts;
          dep_importance = `Essential;
          dep_iface = lib;
          dep_src = false;
          dep_restrictions = [restriction];
          dep_required_commands = [];
          dep_if_os = None;
          dep_use = None;
        }) in

        let progs = impl_provider#get_impls prog in
        let add_requires impl =
          let open Impl in
          if impl.parsed_version >= min_p && impl.parsed_version <= max_p then (
            let new_requires = dep :: impl.props.requires in
            {impl with props = {impl.props with requires = new_requires}}
          ) else impl in
        impl_provider#set_impls prog (List.map add_requires progs);
      ) else failwith line
    )
  );

  let root_req = { Solver.Input.
    role = {
      Solver.scope = (impl_provider :> Impl_provider.impl_provider);
      iface = fst @@ List.hd expected_items;
      source = false
    };
    command = None
  } in
  let result = Solver.do_solve root_req ~closest_match:false in

  match result, root_expected_version with
  | None, "FAIL" ->
      let result = Solver.do_solve root_req ~closest_match:true in
      Fake_system.expect result
  | None, _ -> assert_failure "Expected success, but failed"
  | Some _, "FAIL" -> assert_failure "Expected failure, but found solution!"
  | Some result, _ ->
      let sels = Solver.selections result in
      let actual = ref [] in
      sels |> Selections.iter (fun role sel ->
        let version = Element.version sel in
        actual := (role.Selections.iface, version) :: !actual
      );
      let actual = List.sort compare !actual in
      let expected = List.sort compare expected_items in
      let format_item (prog, version) = Printf.sprintf "%s-%s" prog version in
      let show lst = "[" ^ (String.concat "," (List.map format_item lst)) ^ "]" in
      assert_equal ~printer:show expected actual;
      result

let assertSelection expected problem () = ignore @@ run_sat_test expected problem

let suite = "sat">::: [
  "trivial">:: assertSelection "prog-2" [
    "prog: 1 2";
  ];

  "simple">:: assertSelection "prog-5, liba-5" [
    "prog: 1 2 3 4 5";
    "liba: 1 2 3 4 5";
    "prog[1] => liba 0 4";
    "prog[2] => liba 1 5";
    "prog[5] => liba 4 5";
  ];

  "bestImpossible">:: assertSelection "prog-1" [
    "prog: 1 2";
    "liba: 1";
    "prog[2] => liba 3 4";
  ];

  "slow">:: assertSelection "prog-1" [
    "prog: 1 2 3 4 5 6 7 8 9";
    "liba: 1 2 3 4 5 6 7 8 9";
    "libb: 1 2 3 4 5 6 7 8 9";
    "libc: 1 2 3 4 5 6 7 8 9";
    "libd: 1 2 3 4 5 6 7 8 9";
    "libe: 1";
    "prog[2,9] => liba 1 9";
    "liba[1,9] => libb 1 9";
    "libb[1,9] => libc 1 9";
    "libc[1,9] => libd 1 9";
    "libd[1,9] => libe 0 0";
  ];

  "noSolution">:: assertSelection "prog-FAIL" [
    "prog: 1 2 3";
    "liba: 1";
    "prog[1,3] => liba 2 3";
  ];

  "backtrackSimple">::
    (* We initially try liba-3 before learning that it *)
    (* is incompatible and backtracking. *)
    (* We learn that liba-3 doesn't work ever. *)
    assertSelection "prog-1, liba-2" [
      "prog: 1";
      "liba: 1 2 3";
      "prog[1] => liba 1 2";
    ];

  "backtrackLocal">::
    (* We initially try liba-3 before learning that it *)
    (* is incompatible and backtracking. *)
    (* We learn that liba-3 doesn't work with prog-1. *)
    assertSelection "prog-2, liba-2" [
      "prog: 1 2";
      "liba: 1 2 3";
      "prog[1,2] => liba 1 2";
    ];

  "learning">::
    (* Prog-2 depends on libb and libz, but we can't have both *)
    (* at once. The learning means we don't have to explore every *)
    (* possible combination of liba and libb. *)
    assertSelection "prog-1" [
      "prog: 1 2";
      "liba: 1 2 3";
      "libb Linux-i486: 1 2 3";
      "libz Linux-x86_64: 1 2";
      "prog[2] => liba 1 3";
      "prog[2] => libz 1 2";
      "liba[1,3] => libb 1 3";
    ];

  "toplevelConflict">::
    (* We don't detect the conflict until we start solving, but the *)
    (* conflict is top-level so we abort immediately without *)
    (* backtracking. *)
    assertSelection "prog-FAIL" [
      "prog Linux-i386: 1";
      "liba Linux-x86_64: 1";
      "prog[1] => liba 1 1";
    ];

  "diamondConflict">::
    (* prog depends on liba and libb, which depend on incompatible *)
    (* versions of libc. *)
    assertSelection "prog-FAIL" [
      "prog: 1";
      "liba: 1";
      "libb: 1";
      "libc: 1 2";
      "prog[1] => liba 1 1";
      "prog[1] => libb 1 1";
      "liba[1] => libc 1 1";
      "libb[1] => libc 2 3";
    ];

  "overbacktrack">::
    (* After learning that prog-3 => m0 we backtrack all the way up to the prog-3
     * assignment, unselecting liba-3, and then select it again. *)
    assertSelection "prog-3, liba-3, libb-3, libc-1, libz-2" [
      "prog: 1 2 3";
      "liba: 1 2 3";
      "libb: 1 2 3";
      "libc Linux-x86_64: 2 3";
      "libc Linux-i486: 1";
      "libz Linux-i386: 1 2";
      "prog[2,3] => liba 1 3";
      "prog[2,3] => libz 1 2";
      "liba[1,3] => libb 1 3";
      "libb[1,3] => libc 1 3";
    ];

  "failState">:: (fun () ->
    (* If we can't select a valid combination,
     * try to select as many as we can. *)
    let s = run_sat_test "prog-FAIL" [
      "prog: 1 2";
      "liba: 1 2";
      "libb: 1 2";
      "libc: 5";
      "prog[1,2] => liba 1 2";
      "liba[1,2] => libb 1 2";
      "libb[1,2] => libc 0 0";
    ] in
    let selected = ref XString.Map.empty in
    Solver.selections s |> Selections.iter (fun role sel ->
      let iface = role.Selections.iface in
      selected := XString.Map.add iface (Element.version_opt sel) !selected
    );
    assert_equal (Some "2") (XString.Map.find_safe "prog" !selected);
    assert_equal (Some "2") (XString.Map.find_safe "liba" !selected);
    assert_equal (Some "2") (XString.Map.find_safe "libb" !selected);
    assert_equal None       (XString.Map.find_safe "libc" !selected);
  );

  "coverage">:: (fun () ->
    (* Try to trigger some edge cases... *)

    (* An at_most_one clause must be analysed for causing a conflict. *)
    let sat = S.create () in
    let v1 = S.add_variable sat "v1" in
    let v2 = S.add_variable sat "v2" in
    let v3 = S.add_variable sat "v3" in
    ignore @@ S.at_most_one sat [v1; v2];
    S.at_least_one sat [v1; S.neg v3];
    S.at_least_one sat [v2; S.neg v3];
    S.at_least_one sat [v1; v3];
    let () =
      match S.run_solver sat (fun () -> Some v3) with
      | None -> assert false
      | Some solution ->
          assert_equal true @@ solution v1;
          assert_equal false @@ solution v2;
          assert_equal false @@ solution v3 in

    match S.run_solver sat (fun () -> None) with
    | None -> assert false
    | Some solution ->
        assert_equal true @@ solution v1;
        assert_equal false @@ solution v2;
        assert_equal false @@ solution v3;
  );

  "watch">:: (fun () ->
    let sat = S.create () in

    let a = S.add_variable sat "a" in
    let b = S.add_variable sat "b" in
    let c = S.add_variable sat "c" in

    (* Add a clause. It starts watching the first two variables (a and b). *)
    S.at_least_one sat [a; b; c];

    (* b is False, so it switches to watching a and c *)
    S.at_least_one sat [S.neg b];

    (* Try to trigger bug. *)
    S.at_least_one sat [c];

    let decisions = ref [a] in
    let solution = S.run_solver sat (fun () ->
      match !decisions with
      | next :: rest -> decisions := rest; Some next
      | [] -> assert false
    ) in
    assert (!decisions = []);	(* All used up *)

    match solution with
    | None -> assert false
    | Some solution ->
        assert (solution a);
        assert (not @@ solution b);
        assert (solution c);
  )
]
