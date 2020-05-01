(* Copyright (C) 2020, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit2

module StringData =
  struct
    type t = string
    let pp = Format.pp_print_string
  end

module Sat = Zeroinstall_solver.Sat.Make(StringData)

let suite = "solver">::: [
  "sat_simple">:: (fun _ ->
    let open Sat in
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

  "sat_analyse">:: (fun _ ->
    let open Sat in
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

  "sat_at_most">:: (fun _ ->
    let open Sat in
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
]

let () =
  OUnit2.run_test_tt_main suite
