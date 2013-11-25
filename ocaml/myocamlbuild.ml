(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Ocamlbuild_plugin

let on_windows = Sys.os_type = "Win32"

let print_info f =
  Format.fprintf Format.std_formatter
    "@[<hv 2>Tags for file %s:@ %a@]@." f
    Tags.print (tags_of_pathname f)

(* From Unix.ml (not exported) *)
let rec waitpid_non_intr pid =
  try Unix.waitpid [] pid
  with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_non_intr pid

let get_version package =
  let c_out, c_in, c_err = Unix.open_process_full ("ocamlfind query -format %v " ^ package) (Unix.environment ()) in
  let version =
    try
      let v = input_line c_out in
      (* Printf.printf "version(%s) = %s\n" package v; *)
      if v = "" then None else Some v
    with End_of_file -> None in
  match Unix.close_process_full (c_out, c_in, c_err) with
  | Unix.WEXITED 0 -> version
  | _ -> None

let () =
  let v = Sys.ocaml_version in
  let first_dot = String.index v '.' in
  let second_dot = String.index_from v (first_dot + 1) '.' in
  let major_version = int_of_string (String.sub v 0 first_dot) in
  let minor_version = int_of_string (String.sub v (first_dot + 1) (second_dot - first_dot - 1)) in

  let native_targets = ref ["static_0install.native"] in

  if Sys.os_type = "Win32" then native_targets := "runenv.native" :: !native_targets;

  let use_dbus =
    if on_windows then false
    else (
      match get_version "obus" with
      | Some _ -> true
      | None ->
          print_endline "obus not found; compiling without D-BUS support";
          false
    ) in

  let use_ounit = get_version "oUnit" <> None in

  if use_ounit then
    native_targets := "tests/test.native" :: !native_targets
  else
    print_endline "oUnit not found; not building unit-tests";

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

    if use_dbus then tag_any ["package(obus,obus.notification,obus.network-manager)"];

    pdep ["link"] "linkdep_win" (fun param -> if on_windows then [param] else []);
    pdep ["link"] "link" (fun param -> [param]);

    (* We use mypp rather than camlp4of because if you pass -pp and -ppopt to ocamlfind
       then it just ignores the ppopt. So, we need to write the -pp option ourselves. *)

    let defines_portable = List.concat [
      if (major_version < 4 || (major_version == 4 && minor_version < 1)) then [A"-DOCAML_LT_4_01"] else [];
      if use_dbus then [A"-DHAVE_DBUS"] else [];
    ] in

    let defines_native =
      if on_windows then A"-DWINDOWS" :: defines_portable
      else defines_portable in

    flag ["native";"ocaml";"pp";"mypp"] (S (A "camlp4of" :: defines_native));
    flag ["byte";"ocaml";"pp";"mypp"] (S (A "camlp4of" :: defines_portable));

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

