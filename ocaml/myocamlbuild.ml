(* Copyright (C) 2017, Thomas Leonard
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

type details = {
  version : string;
  dir : string;
}

let ci_build =
  try Sys.getenv "CI" = "true"
  with Not_found -> false

let get_info package =
  (* Windows can't handle newlines or tabs in the format string, so use ASCII unit separator. *)
  let c_out, c_in, c_err = Unix.open_process_full ("ocamlfind query -format %v\x1f%d " ^ package) (Unix.environment ()) in
  let info =
    try
      let record = input_line c_out in
      let sep = String.index record '\x1f' in
      let dir_len = String.length record - sep - 1 in
      let dir_len =
        if record.[sep + dir_len] = '\r' then dir_len - 1 else dir_len in
      let version = String.sub record 0 sep in
      let dir = String.sub record (sep + 1) dir_len in
      (* Printf.printf "version(%s) = %s\n" package version; *)
      Some {version; dir}
    with End_of_file -> None in
  match Unix.close_process_full (c_out, c_in, c_err) with
  | Unix.WEXITED 0 -> info
  | _ -> None

let rec parse_version v =
  try
    try
      let i = String.index v '.' in
      let rest = String.sub v (i + 1) (String.length v - i - 1) in
      int_of_string (String.sub v 0 i) :: parse_version rest
    with Not_found ->
      [int_of_string v]
  with ex ->
    Printf.fprintf stderr "Can't parse version '%s': %s\n" v (Printexc.to_string ex);
    flush stderr;
    []

let add x xs = xs := A x :: !xs

let windres =
  match on_windows with
  | false -> ""
  | true ->
    try
      match Sys.getenv "WINDRES" with
      | "" -> raise Not_found
      | x  -> x
    with
    | Not_found ->
      if Sys.word_size = 32 then
        "i686-w64-mingw32-windres.exe"
      else
        "x86_64-w64-mingw32-windres.exe"

let () =
  let native_targets = ref ["static_0install.native"] in

  if Sys.os_type = "Win32" then native_targets := "runenv.native" :: !native_targets;

  let use_dbus =
    if on_windows then false
    else (
      match get_info "obus" with
      | Some {version;_} when parse_version version < [1;1;5] ->
          (* Or you get: No implementations provided for the following modules: Toploop *)
          print_endline "obus is too old (< 1.1.5); compiling without D-BUS support";
          false
      | Some _ -> true
      | None ->
          print_endline "obus not found; compiling without D-BUS support";
          false
    ) in

  let use_ounit = get_info "oUnit" <> None in

  if use_ounit then
    native_targets := "tests/test.native" :: !native_targets
  else
    print_endline "oUnit not found; not building unit-tests";

  let gtk_dir =
    match get_info "lablgtk2" with
    | None -> print_endline "lablgtk2 not found; not building GTK GUI plugin"; None
    | Some {version=_; dir} -> native_targets := "gui_gtk.cmxs" :: !native_targets; Some dir in

  let to_byte name =
    if Pathname.check_extension name "native" then Pathname.update_extension "byte" name
    else if Pathname.check_extension name "cmxs" then Pathname.update_extension "cma" name
    else name in
  let byte_targets = List.map to_byte !native_targets in

  (* When building byte-code, we need -custom to include the C code *)
  flag ["link"; "ocaml"; "byte"] (A"-custom");

  dispatch (function
  | Before_options ->
      Options.make_links := false;
      Options.use_ocamlfind := true;
      Options.build_dir := Filename.dirname Pathname.pwd ^ "/build/ocaml";  (* Default if run manually *)
  | After_rules ->
    rule "Build everything (native)"
      ~prod:"all-native.otarget"
      ~deps:!native_targets
      (fun _ _ -> Command.Nop);

    rule "Build everything (byte-code)"
      ~prod:"all-byte.otarget"
      ~deps:byte_targets
      (fun _ _ -> Command.Nop);

    if on_windows then (
      (* We need an XML manifest, or Windows 7 won't run it because it has "install" in its name. *)
      rule ".rc.o" ~deps:["%.rc";"%.manifest"] ~prod:"%.o"
        (fun env _ ->
          let rc = env "%.rc" and o = env "%.o" in
          Cmd (S [P windres;A "--input-format";A "rc";A "--input";P rc;
                  A "--output-format";A "coff";A "--output"; Px o]))
    );

    if use_dbus then tag_any ["package(obus,obus.notification,obus.network-manager)"];

    pdep ["link"] "linkdep_win" (fun param -> if on_windows then [param] else []);
    pdep ["link"] "link" (fun param -> [param]);

    begin match get_info "curl" with
    | None -> failwith "Missing ocurl!"
    | Some {version; dir = _} ->
      if parse_version version < [0; 7; 1] then
        failwith "ocurl is too old - need 0.7.1 or later"
    end;

    let have_sha = get_info "sha" <> None in

    if not have_sha then (
      flag ["compile"] (S [A"-package"; A"ssl"]);
      flag ["link"] (S [A"-package"; A"ssl"]);
    );

    begin match gtk_dir with
    | Some gtk_dir ->
        let lwt_dir =
          match get_info "lwt.glib" with
          | Some {version=_; dir} -> dir
          | None -> failwith "lablgtk2 is present, but missing lwt.glib dependency!" in
        (* ("-thread" is needed on Ubuntu 13.04 for some reason, even though it's in the _tags too) *)
        flag ["library"; "shared"; "native"; "link_gtk"] (S [A"-thread"; A (gtk_dir / "lablgtk.cmxa"); A (lwt_dir / "lwt-glib.cmxa")]);
        flag ["library"; "byte"; "link_gtk"] (S [A"-thread"; A (gtk_dir / "lablgtk.cma"); A (lwt_dir / "lwt-glib.cma")]);
    | None -> () end;

    (* We use mypp rather than camlp4of because if you pass -pp and -ppopt to ocamlfind
       then it just ignores the ppopt. So, we need to write the -pp option ourselves. *)

    let defines_portable = ref [] in
    if use_dbus then add "-DHAVE_DBUS" defines_portable;
    if gtk_dir <> None then add "-DHAVE_GTK" defines_portable;

    if have_sha then (
      (* Use "sha" package instead of libcrypto *)
      add "-DHAVE_SHA" defines_portable;
      flag ["compile"; "link_crypto"] (S [A"-ccopt"; A"-DHAVE_SHA"]);
      flag ["compile"; "ocaml"] (S [A"-package"; A"sha"]);
      flag ["link"] (S [A"-package"; A"sha"]);
    ) else (
      print_endline "sha (ocaml-sha) not found; using OpenSSL instead"
    );

    let defines_native = ref !defines_portable in
    if on_windows then add "-DWINDOWS" defines_native;

    if gtk_dir <> None then (
      let add_glib tag =
        flag ["ocaml"; tag] (S[A"-package"; A "dynlink"]) in
      List.iter add_glib ["compile"; "ocamldep"; "doc"; "link"; "infer_interface"]
    );

    flag ["native";"ocaml";"pp";"mypp"] (S (A "camlp4of" :: !defines_native));
    flag ["byte";"ocaml";"pp";"mypp"] (S (A "camlp4of" :: !defines_portable));

    flag ["ocaml";"ocamldep";"mypp"] (S [A"-pp"; A "camlp4of"]);

    (* Make all enabled warnings fatal for CI builds. *)
    if ci_build then flag ["compile"; "ocaml"] (S [A"-warn-error"; A"A-4-48-58"]);

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

