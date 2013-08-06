(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Ocamlbuild_plugin;;

let on_windows = Sys.os_type = "Win32"

let print_info f =
  Format.fprintf Format.std_formatter
    "@[<hv 2>Tags for file %s:@ %a@]@." f
    Tags.print (tags_of_pathname f)

let () =
  dispatch (function
  | After_rules ->
(*     print_info "support/common.ml"; *)
    pdep ["link"] "linkdep_win" (fun param -> if on_windows then [param] else []);

    (* We use mypp rather than camlp4of because if you pass -pp and -ppopt to ocamlfind
       then it just ignores the ppopt. So, we need to write the -pp option ourselves. *)

    let pp_portable = "camlp4of" in
    let pp_native =
      if on_windows then
        "camlp4of -DWINDOWS"
      else
        "camlp4of"
    in
    flag ["native";"ocaml";"compile";"mypp"] (S [A"-pp"; A pp_native]);
    flag ["byte";"ocaml";"compile";"mypp"] (S [A"-pp"; A pp_portable]);

    flag ["ocaml";"ocamldep";"mypp"] (S [A"-pp"; A "camlp4of"]);

    (* Enable most warnings *)
    flag ["compile"; "ocaml"] (S [A"-w"; A"A-4"]);

    pflag [] "dllib" (fun x -> (S [A"-dllib"; A x]));

    (* Code coverage with bisect *)
    flag ["bisect"; "pp"]
      (S [A"camlp4o"; A"str.cma"; A"/usr/lib/ocaml/bisect/bisect_pp.cmo"]);
    flag ["bisect"; "compile"]
      (S [A"-I"; A"/path/to/bisect"]);
    flag ["bisect"; "link"; "byte"]
      (S [A"-I"; A"/path/to/bisect"; A"bisect.cma"]);
    flag ["bisect"; "link"; "native"]
      (S [A"-I"; A"/path/to/bisect"; A"bisect.cmxa"]);
    flag ["bisect"; "link"; "java"]
      (S [A"-I"; A"/path/to/bisect"; A"bisect.cmja"])
  | _ -> ())

