(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Ocamlbuild_plugin

let on_windows = Sys.os_type = "Win32"

let print_info f =
  Format.fprintf Format.std_formatter
    "@[<hv 2>Tags for file %s:@ %a@]@." f
    Tags.print (tags_of_pathname f)

let () =
  let v = Sys.ocaml_version in
  let first_dot = String.index v '.' in
  let second_dot = String.index_from v (first_dot + 1) '.' in
  let major_version = int_of_string (String.sub v 0 first_dot) in
  let minor_version = int_of_string (String.sub v (first_dot + 1) (second_dot - first_dot - 1)) in

  let native_targets = ref ["static_0install.native"; "tests/test.native"] in

  if Sys.os_type = "Win32" then native_targets := "runenv.native" :: !native_targets;

  let to_byte name =
    if Pathname.check_extension name "native" then Pathname.update_extension "byte" name
    else name in
  let byte_targets = List.map to_byte !native_targets in

  dispatch (function
  | After_rules ->
    rule "Build everything (native)"
      ~prod:"all-native.otarget"
      ~deps:!native_targets
      (fun _ _ -> Command.Nop);

    rule "Build everything (byte-code)"
      ~prod:"all-byte.otarget"
      ~deps:byte_targets
      (fun _ _ -> Command.Nop);

    pdep ["link"] "linkdep_win" (fun param -> if on_windows then [param] else []);
    pdep ["link"] "link" (fun param -> [param]);

    (* We use mypp rather than camlp4of because if you pass -pp and -ppopt to ocamlfind
       then it just ignores the ppopt. So, we need to write the -pp option ourselves. *)

    let pp_portable = "camlp4of" in

    let pp_portable =
      if (major_version < 4 || (major_version == 4 && minor_version < 1)) then
        pp_portable ^ " -DOCAML_LT_4_01"
      else
        pp_portable in

    let pp_native =
      if on_windows then
        pp_portable ^ " -DWINDOWS"
      else
        pp_portable
    in
    flag ["native";"ocaml";"compile";"mypp"] (S [A"-pp"; A pp_native]);
    flag ["byte";"ocaml";"compile";"mypp"] (S [A"-pp"; A pp_portable]);

    flag ["ocaml";"ocamldep";"mypp"] (S [A"-pp"; A "camlp4of"]);

    (* Enable most warnings *)
    flag ["compile"; "ocaml"] (S [A"-w"; A"A-4"; A"-warn-error"; A"+5+6+10+26"]);

    pflag [] "dllib" (fun x -> (S [A"-dllib"; A x]));

    (* (<*.ml> or <support/*.ml> or <zeroinstall/*.ml> or <cmd/*.ml>): bisect, syntax(bisect_pp) *)

    (* Code coverage with bisect *)
    let coverage =
      try Sys.getenv "OCAML_COVERAGE" = "true"
      with Not_found -> false in

    if coverage then (
      flag ["compile"; "ocaml"] (S [A"-package"; A"bisect"; A"-syntax"; A"camlp4o"]);
      flag ["link"] (S [A"-package"; A"bisect"]);
    );
  | _ -> ()
  )

