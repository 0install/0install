(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Common

module U = Utils

let spf = Printf.sprintf

type fingerprint = string
type timestamp = float

type sig_error =
  | UnsupportedAlgorithm of string
  | UnknownKey of string
  | UnknownSigError of int

type valid_details = {
  fingerprint : fingerprint;
  timestamp : timestamp;
}

type signature =
  | ValidSig of valid_details
  | BadSig of string      (* Message has been tampered with *)
  | ErrSig of sig_error

let string_of_sig = function
  | ValidSig details -> spf "Valid signature from %s" details.fingerprint
  | BadSig key -> spf "BAD signature by %s (the message has been tampered with)" key
  | ErrSig (UnsupportedAlgorithm alg) -> spf "Unknown or unsupported algorithm '%s'" alg
  | ErrSig (UnknownKey key) -> spf "Unknown key. Try 'gpg --recv-key %s'" key
  | ErrSig (UnknownSigError code) -> spf "Unknown reason code from GPG: %d" code

let re_xml_comment_start = Str.regexp "^<!-- Base64 Signature$"

let re_newline = Str.regexp "[\n\r]+"

let gnupg_options = ref None

let get_gnupg_options system =
  let gpg_path =
    match system#getenv "ZEROINSTALL_GPG" with
    | Some path -> path
    | None ->
        match U.find_in_path system "gpg" with
        | Some path -> path
        | None ->
            match U.find_in_path system "gpg2" with
            | Some path -> path
            | None -> raise_safe "Can't find gpg or gpg2 in $PATH!" in

  let gnupg_options = [gpg_path; "--no-secmem-warning"] in

  if system#running_as_root && system#getenv "GNUPGHOME" = None then (
    let gnupg_home = Basedir.get_unix_home system +/ ".gnupg" in
    log_info "Running as root, so setting GnuPG home to %s" gnupg_home;
    gnupg_options @ ["--homedir"; gnupg_home]
  ) else gnupg_options

let make_gpg_command system args =
  let opts =
    match !gnupg_options with
    | None ->
        let opts = get_gnupg_options system in
        gnupg_options := Some opts;
        opts
    | Some opts -> opts in
  let argv = opts @ args in
  log_info "Running GnuPG: %s" (Logging.format_argv_for_logging argv);
  (List.hd opts, argv |> Array.of_list)

(** Run gpg, passing [stdin] as input and collecting the output. *)
let run_gpg_full system ?stdin args =
  let command = make_gpg_command system args in
  let child = new Lwt_process.process_full command in
  try_lwt
    (* Start collecting output... *)
    let stdout = Lwt_io.read child#stdout in
    let stderr = Lwt_io.read child#stderr in

    (* At the same time, write the input, if any *)
    lwt () =
      match stdin with
      | None -> Lwt.return ()
      | Some stdin -> stdin child#stdin in

    lwt () = Lwt_io.close child#stdin in

    (* Join the collection threads *)
    lwt stdout = stdout in
    lwt stderr = stderr in
    log_info "GPG: output:\n%s" stdout;
    log_info "GPG: errors:\n%s" stderr;
    lwt status = child#close in
    Lwt.return (stdout, stderr, status)
  with ex ->
    (* child#terminate; - not in Debian *)
    ignore child#close;
    raise ex

(** Run gpg, passing [stdin] as input and collecting the output.
 * If the command returns an error, report stderr as the error (on success, stderr is discarded).
 *)
let run_gpg system ?stdin args =
  lwt stdout, stderr, status = run_gpg_full system ?stdin args in
  match status with
  | Unix.WEXITED 0 -> Lwt.return stdout
  | status ->
      if stderr = "" then System.check_exit_status status;
      raise_safe "GPG failed: %s" stderr

(** Run "gpg --import" with this data as stdin. *)
let import_key system key_data =
  let write_stdin stdin = Lwt_io.write stdin key_data in
  lwt output = run_gpg system ~stdin:write_stdin ["--quiet"; "--import"; "--batch"] in
  if output <> "" then
    log_warning "Output from gpg:\n%s" output;
  Lwt.return ()

(** Call 'gpg --list-keys' and return the results split into lines and columns. *)
let get_key_details system key_id : string array list Lwt.t =
  (* Note: GnuPG 2 always uses --fixed-list-mode *)
  lwt output = run_gpg system ["--fixed-list-mode"; "--with-colons"; "--list-keys"; "--"; key_id] in
  let parse_line line = Str.split U.re_colon line |> Array.of_list in
  output |> Str.split re_newline |> List.map parse_line |> Lwt.return

(** Get the first human-readable name from the details. *)
let get_key_name system key_id =
  lwt details = get_key_details system key_id in
  details |> U.first_match ~f:(fun details ->
    if Array.length details > 9 && details.(0) = "uid" then Some details.(9)
    else None
  ) |> Lwt.return

let find_sig_end xml =
  let rec skip_ws last =
    match xml.[last - 1] with
    | ' ' | '\n' | '\r' | '\t' -> skip_ws (last - 1)
    | _ -> last in

  let last_non_ws = skip_ws (String.length xml) in

  let end_marker_index = last_non_ws - 4 in
  if String.sub xml end_marker_index 4 <> "\n-->" then
    raise_safe "Bad signature block: last line is not end-of-comment";

  let rec skip_padding last =
    match xml.[last - 1] with
    | ' ' | '\n' | '\t' | '\r' | '=' -> skip_padding (last - 1)
    | _ -> last in

  skip_padding end_marker_index

(* The docs say GnuPG timestamps can be seconds since the epoch or an ISO 8601
   string ("we are migrating to an ISO 8601 format"). We use --fixed-list-mode,
   which says it will "print all timestamps as seconds since 1970-01-01 [...]
   Since GnuPG 2.0.10, this mode is always used and thus this option is
   obsolete; it does not harm to use it though." *)
let parse_timestamp ts =
  float_of_string ts

let make_valid args = ValidSig {
  fingerprint = args.(0);
  timestamp = parse_timestamp args.(2);
}

let make_bad args = BadSig args.(0)

let make_err args = ErrSig (
  match U.safe_int_of_string args.(5) with
  | 4 -> UnsupportedAlgorithm args.(1)
  | 9 -> UnknownKey args.(0)
  | x -> UnknownSigError x
)

(** Parse the status output from gpg as a list of signatures. *)
let sigs_from_gpg_status_output status =
  status |> Str.split re_newline |> U.filter_map ~f:(fun line ->
    if U.starts_with line "[GNUPG:] " then (
      match U.string_tail line 9 |> Str.split_delim U.re_space with
      | [] -> None
      | code :: args ->
          let args = Array.of_list args in
          match code with
          | "VALIDSIG" -> Some (make_valid args)
          | "BADSIG" -> Some (make_bad args)
          | "ERRSIG" -> Some (make_err args)
          | _ -> None
    ) else (
      (* The docs says every line starts with this, but if auto-key-retrieve
       * is on then they might not. See bug #3420548 *)
      log_warning "Invalid output from GnuPG: %s" (String.escaped line);
      None
    )
  )

(** Verify the GPG signature at the end of data. *)
let verify (system:system) xml =
  if not (U.starts_with xml "<?xml ") then (
    let len = min 120 (String.length xml) in
    let start = String.sub xml 0 len |> String.escaped in
    raise_safe "This is not a Zero Install feed! It should be an XML document, but it starts:\n%s" start
  ) else (
    let index =
      try Str.search_backward re_xml_comment_start xml (String.length xml)
      with Not_found ->
        raise_safe "No signature block in XML. Maybe this file isn't signed?" in

    let sig_start = String.index_from xml index '\n' in
    let sig_end = find_sig_end xml in
    let base64_data = String.sub xml sig_start (sig_end - sig_start) |> Str.global_replace re_newline "" in
    let sig_data =
      try Base64.str_decode base64_data
      with Base64.Invalid_char -> raise_safe "Invalid characters found in base 64 encoded signature" in

    let tmp = Filename.temp_file "0install" "-gpg" in
    lwt (stdout, stderr, exit_status) = Lwt.finalize
      (fun () ->
        lwt () =
          Lwt_io.with_file ~flags:[Unix.O_WRONLY] ~mode:Lwt_io.output tmp (fun ch ->
            Lwt_io.write ch sig_data
          ) in

        let write_stdin stdin = Lwt_io.write_from_exactly stdin xml 0 index in
        run_gpg_full system ~stdin:write_stdin [
            (* Not all versions support this: *)
            (* '--max-output', str(1024 * 1024), *)
            "--batch";
            (* Windows GPG can only cope with "1" here *)
            "--status-fd"; "1";
            (* Don't try to download missing keys; we'll do that *)
            "--keyserver-options"; "no-auto-key-retrieve";
            "--verify"; tmp; "-";
          ]
      )
      (fun () -> Unix.unlink tmp |> Lwt.return) in

    ignore exit_status;
    Lwt.return (sigs_from_gpg_status_output stdout, trim stderr)
  )

type key_info = {
  name : string option
}

(** Load a set of keys at once.
    This is much more efficient than making individual calls to [load_key]. *)
let load_keys system fingerprints =
  if fingerprints = [] then (
    (* Otherwise GnuPG returns everything... *)
    Lwt.return StringMap.empty
  ) else (
    lwt output = run_gpg system @@ [
      "--fixed-list-mode"; "--with-colons"; "--list-keys";
      "--with-fingerprint"; "--with-fingerprint"] @ fingerprints in

    let keys = ref StringMap.empty in

    fingerprints |> List.iter (fun fpr ->
      keys := StringMap.add fpr ({name = None}) !keys
    );

    let current_fpr = ref None in
    let current_uid = ref None in

    let maybe_set_name fpr name =
      if StringMap.mem fpr !keys then
        keys := StringMap.add fpr {name = Some name} !keys in

    output |> Str.split re_newline |> List.iter (fun line ->
      if U.starts_with line "pub:" then (
        current_fpr := None; current_uid := None
      ) else if U.starts_with line "fpr:" then (
        let fpr = List.nth (line |> Str.split_delim U.re_colon) 9 in
        current_fpr := Some fpr;
        match !current_uid with
        | None -> ()
        | Some uid ->
            (* This is probably a subordinate key, where the fingerprint
             * comes after the uid, not before. Note: we assume the subkey is
             * cross-certified, as recent always ones are. *)
            maybe_set_name fpr uid
      ) else if U.starts_with line "uid:" then (
        match !current_fpr with
        | None -> assert false
        | Some fpr ->
            (* Only take primary UID *)
            if !current_uid = None then (
              let uid = List.nth (line |> Str.split_delim U.re_colon) 9 in
              maybe_set_name fpr uid;
              current_uid := Some uid
            )
      )
    );
        
    Lwt.return !keys
  )
