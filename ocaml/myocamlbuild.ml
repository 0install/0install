(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Ocamlbuild_plugin;;

let on_windows = Sys.os_type = "Win32";;

dispatch (function
  | After_rules ->
    pdep ["link"] "linkdep_win" (fun param -> if on_windows then [param] else []);

    (* We use mypp rather than camlp4of because if you pass -pp and -ppopt to ocamlfind
       then it just ignores the ppopt. So, we need to write the -pp option ourselves. *)
    let pp = if on_windows then "camlp4of -DWINDOWS" else "camlp4of" in
    flag ["ocaml";"compile";"mypp"] (S [A"-pp"; A pp]);
    flag ["ocaml";"ocamldep";"mypp"] (S [A"-pp"; A pp])
  | _ -> ())
