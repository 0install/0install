(* Copyright (C) 2020, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit2

let assert_string_equal a b = assert_equal ~printer:(fun x -> x) a b

module StringData =
  struct
    type t = string
    let pp = Format.pp_print_string
  end

module Sat = Zeroinstall_solver.Sat.Make(StringData)

module Model = struct
  type command = string
  type command_name = string

  type restriction = [`Not_before of int]

  type role = string * impl list
  and dep_info = {
    dep_role : role;
    dep_importance : [ `Essential | `Recommended | `Restricts ];
    dep_required_commands : command_name list;
  }
  and impl = {
    version : int;
    impl_deps : dependency list;
    conflict_class : string list;
  }
  and dependency = role * restriction list

  module Role = struct
    type t = role
    let pp f (id, _) = Format.pp_print_string f id
    let compare a b = compare (fst a) (fst b)
  end

  type requirements = {
    role : Role.t;
    command : command_name option;
  }

  let requires _role impl = impl.impl_deps, []

  let dep_info (dep_role, _) = { dep_role; dep_importance = `Essential; dep_required_commands = [] }

  let command_requires _role _command = [], []

  let get_command _impl _ = None

  type role_information = {
    replacement : Role.t option;
    impls : impl list;
  }

  type machine_group = string

  let pp_impl f impl = Format.pp_print_int f impl.version
  let pp_command = Format.pp_print_string

  let implementations (_, impls) = { replacement = None; impls }

  let restrictions (_, rs) = rs
  let meets_restriction impl (`Not_before min) = impl.version >= min

  let machine_group _impl = None

  type conflict_class = string
  let conflict_class impl = impl.conflict_class

  type rejection = string

  let rejects _role = [], []

  let compare_version a b = compare b.version a.version
  let pp_version f impl = Format.pp_print_int f impl.version

  let user_restrictions _role = None

  let pp_impl_long = pp_version
  let format_machine _impl = "(any)"
  let string_of_restriction (`Not_before x) = Printf.sprintf ">= %d" x
  let describe_problem _impl x = x

  let dummy_impl = { version = -1; impl_deps = []; conflict_class = [] }
end

module Opam_test = struct
  open Model

  let ocaml_4_08 = { version = 408; impl_deps = []; conflict_class = ["compiler"] }
  let beta_ocaml_4_09 = { version = 409; impl_deps = []; conflict_class = ["compiler"] }
  let ocaml_compiler = "ocaml", [ocaml_4_08]
  let beta_ocaml_compiler = "beta-ocaml", [beta_ocaml_4_09]

  let app = { version = 1;
              conflict_class = [];
              impl_deps = [
                ocaml_compiler, [];
                beta_ocaml_compiler, [];
              ]
            }

  let app_role = "app", [app]

  let expected = String.trim {|
Can't find all required implementations:
- app -> 1
- beta-ocaml -> (problem)
    Rejected candidates:
      409: In same conflict class (compiler) as ocaml
- ocaml -> 408
|}

end

module Solver = Zeroinstall_solver.Make(Model)
module Diagnostics = Zeroinstall_solver.Diagnostics(Solver.Output)

let get_diagnostics reqs =
  match Solver.do_solve ~closest_match:false reqs with
  | Some s ->
    let b = Buffer.create 1024 in
    Buffer.add_string b "Solve should have failed, but got:\n";
    Solver.Output.to_map s |> Solver.Output.RoleMap.iter (fun (role, _) impl ->
        let msg = Printf.sprintf "%s -> %d\n" role (Solver.Output.unwrap impl).Model.version in
        Buffer.add_string b msg
      );
    OUnit2.assert_failure (Buffer.contents b)
  | None ->
    match Solver.do_solve ~closest_match:true reqs with
    | None -> OUnit2.assert_failure "Diagnostics should not have failed!"
    | Some results -> Diagnostics.get_failure_reason results

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

  "conflict-classes">:: (fun _ ->
      let reqs = { Model.role = Opam_test.app_role; command = None } in
      assert_string_equal Opam_test.expected @@ get_diagnostics reqs
    )
]

let () =
  OUnit2.run_test_tt_main suite
