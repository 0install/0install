(* This is needed because ocamlbuild 3.12.1 doesn't support absolute pathnames (4.00.1 does)
   And 4.01.0 fails when given a relative path ("Failure: Pathname.normalize_list: .. is forbidden here.") *)

#load "str.cma";;
#load "unix.cma";;

let re_OCAMLLIB = Str.regexp_string "OCAMLLIB="

let (|>) f x = x f

let make_relative path =
  if path.[0] = '/' then (
    let cwd = Unix.getcwd () in
    let rel_path = ref (".." ^ path) in
    for i = 1 to String.length cwd - 1 do
      if cwd.[i] = '/' then rel_path := "../" ^ !rel_path
    done;
    !rel_path
  ) else path   (* Already relative *)

let () =
  match Sys.argv with
  | [| _prog; ocaml_build_dir; make_path |] ->
      let ch = Unix.open_process_in "ocamlbuild -version" in
      let ocamlbuild_version = input_line ch in
      let need_relative_path = Str.string_match (Str.regexp "ocamlbuild 3") ocamlbuild_version 0 in

      let ocaml_build_dir =
        if need_relative_path then make_relative ocaml_build_dir
        else ocaml_build_dir in

      (* Hack: when we can depend on a full OCaml feed with the build tools, we can remove this.
         Until then, we need to avoid trying to compile against the limited runtime environment. *)
      let env = Unix.environment ()
      |> Array.to_list
      |> List.filter (fun pair -> not (Str.string_match re_OCAMLLIB pair 0))
      |> Array.of_list in

      Unix.execvpe make_path [| make_path; "OCAML_BUILDDIR=" ^ ocaml_build_dir |] env
  | _ -> failwith "usage: ocaml build-in.ml builddir"
