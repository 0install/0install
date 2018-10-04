(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Managing cached implementations *)

open General
open Support
open Support.Common
module Q = Support.Qdom
module U = Support.Utils

type stores = string list

type available_digests = (string, filepath) Hashtbl.t

exception Not_stored of string

let first_match = Support.Utils.first_match

let lookup_digest (system:#filesystem) stores digest =
  let check_store store = (
    let path = Filename.concat store (Manifest.format_digest digest) in
    if system#file_exists path then Some path else None
  ) in first_match check_store stores

let lookup_maybe system digests stores = first_match (lookup_digest system stores) digests

let lookup_any system digests stores =
  match lookup_maybe system digests stores with
  | Some path -> path
  | None ->
      let str_digests = String.concat "|" (List.map Manifest.format_digest digests) in
      let str_stores = String.concat "\n- " stores in
      raise (Not_stored ("Item with digest " ^ str_digests ^ " not found in stores. Searched:\n- " ^ str_stores))

let read_impl_dirs (system:#filesystem) paths =
  (* Read the old implementation-dirs configuration file *)
  let extra_impl_dirs = ref [] in
  Paths.Config.(all_paths implementation_dirs) paths
  |> List.iter (fun path ->
    try
      if system#file_exists path then (
        let re_cache_dir = Str.regexp "^\\([^#].*\\)$" in
        path |> system#with_open_in [Open_rdonly] (fun ch ->
          try
            while true do
              let line = input_line ch in
              if Str.string_match re_cache_dir line 0 then (
                let impl_dir = Str.matched_group 1 line in
                extra_impl_dirs := impl_dir :: !extra_impl_dirs
              )
            done
          with End_of_file -> ()
        )
      )
    with ex -> log_warning ~ex "Error reading config file '%s'" path
  );
  !extra_impl_dirs

let get_default_stores system paths =
  Paths.Cache.(all_paths implementations) paths
  @ read_impl_dirs system paths

let get_available_digests (system:#filesystem) stores =
  let digests = Hashtbl.create 1000 in
  let scan_dir dir =
    match system#readdir dir with
    | Ok items ->
        for i = 0 to Array.length items - 1 do
          Hashtbl.add digests items.(i) dir
        done
    | Error (Sys_error _) -> ()
    | Error _ -> log_debug "Can't scan %s" dir
    in
  List.iter scan_dir stores;
  digests

let check_available available_digests digests =
  List.exists (fun d -> Hashtbl.mem available_digests (Manifest.format_digest d)) digests

let get_digests elem =
  let digests = ref [] in

  let id = Element.id elem in
  let same_as_id =
    match Str.bounded_split_delim XString.re_equals id 2 with
    | ["sha1" | "sha1new" | "sha256" as key; value] ->
        let digest = (key, value) in
        digests := [digest];
        (=) digest
    | _ -> fun _ -> false in

  Element.as_xml elem |> ZI.iter ~name:"manifest-digest" (fun manifest_digest ->
    manifest_digest.Q.attrs |> Q.AttrMap.iter_values (fun (ns, name) value ->
      let digest = (name, value) in
      if ns = "" && not (same_as_id digest) then digests := digest :: !digests
    )
  );
  !digests

(* Preferred algorithms score higher. None if we don't support this algorithm at all. *)
let score_alg = function
  | "sha256new" -> Some 90
  | "sha256"    -> Some 80
  | "sha1new"   -> Some 50
  | "sha1"      -> Some 10
  | _ -> None

let best_digest digests =
  let best = ref None in
  digests |> List.iter (fun digest ->
    match score_alg (fst digest) with
    | None -> ()
    | Some score ->
        match !best with
        | Some (old_score, _) when old_score >= score -> ()
        | _ -> best := Some (score, digest)
  );
  match !best with
  | Some (_score, best) -> best
  | None ->
      let algs = digests |> List.map fst |> String.concat ", " in
      Safe_exn.failf "None of the candidate digest algorithms (%s) is supported" algs

let make_tmp_dir (system:#filesystem) = function
  | store :: _ ->
      let mode = 0o755 in     (* r-x for all; needed by 0store-helper *)
      U.makedirs system store mode;
      system#chmod store mode;  (* arg to makedirs not sufficient; must clear setgid too *)
      U.make_tmp_dir system ~mode store
  | _ -> Safe_exn.failf "No stores configured!"

(** Copy the contents of [srcdir] into [dstdir] (which must be empty).
 * Permissions on the new copies will be 555 or 444. mtimes are copied. *)
let rec copy_tree system srcdir dstdir =
  match system#readdir srcdir with
  | Error ex -> raise ex
  | Ok items ->
      items |> Array.iter (fun item ->
        assert (item <> "." && item <> "..");

        let src_path = srcdir +/ item in
        let dst_path = dstdir +/ item in
        let src_info = system#lstat src_path |? lazy (Safe_exn.failf "Path '%s' has disappeared!" src_path) in

        begin match src_info.Unix.st_kind with
        | Unix.S_DIR ->
            system#mkdir dst_path 0o700;
            copy_tree system src_path dst_path;
            system#chmod dst_path 0o555;
            system#set_mtime dst_path src_info.Unix.st_mtime
        | Unix.S_REG ->
            let mode = if (src_info.Unix.st_perm land 0o111) <> 0 then 0o555 else 0o444 in
            U.copy_file system src_path dst_path mode;
            system#set_mtime dst_path src_info.Unix.st_mtime
        | Unix.S_LNK ->
            let linkto = system#readlink src_path |? lazy (Safe_exn.failf "Failed to read symlink target '%s'" src_path) in
            system#symlink ~target:linkto ~newlink:dst_path
        | _ -> Safe_exn.failf "Not a regular file/directory/symlink '%s'" src_path end;
      )

(** Rename or move [tmpdir] as [store]/[digest]. The digest is not checked here.
 * If the target already exists, we just delete [tmpdir]. *)
let add_to_store config store digest tmpdir =
  U.makedirs config.system store 0o755;
  let path = store +/ (Manifest.format_digest digest) in
  if config.dry_run then (
    Dry_run.log "would store implementation as %s" path;
    config.system#mkdir path 0o755;
    U.rmtree ~even_if_locked:true config.system tmpdir;
  ) else if U.is_dir config.system path then (
    log_info "Target directory already exists in cache: '%s'" path;
    U.rmtree ~even_if_locked:true config.system tmpdir;
  ) else (
    config.system#chmod tmpdir 0o755;
    try
      config.system#rename tmpdir path;
      config.system#chmod path 0o555
    with Unix.Unix_error (Unix.EXDEV, "rename", _) ->
      log_info "Target is on a different filesystem so can't rename; copy and delete instead";
      let target_tmpdir = U.make_tmp_dir config.system ~mode:0o700 store in
      begin try copy_tree config.system tmpdir target_tmpdir;
      with ex -> U.rmtree ~even_if_locked:true config.system target_tmpdir; raise ex end;
      config.system#rename target_tmpdir path;
      config.system#chmod path 0o555;
      U.rmtree ~even_if_locked:true config.system tmpdir;
  )

let add_with_helper config required_digest tmpdir =
  let system = config.system in
  if fst required_digest = "sha1" then Lwt.return `No_helper     (* Old digest alg not supported *)
  else if system#getenv "ZEROINSTALL_PORTABLE_BASE" <> None then Lwt.return `No_helper  (* Can't use helper with portable mode *)
  else (
    match U.find_in_path system "0store-secure-add-helper" with
    | None -> log_info "'0store-secure-add-helper' command not found. Not adding to system cache."; Lwt.return `No_helper
    | Some helper ->
        let digest_str = Manifest.format_digest required_digest in
        if config.dry_run then (
          Dry_run.log "would use %s to store %s in system store" helper digest_str; Lwt.return `Success
        ) else (
          let env = Array.append system#environment [|
            (* (warn about insecure configurations) *)
            "ENV_NOT_CLEARED=Unclean";
            "HOME=Unclean";
          |] in

          let command = (helper, [| helper; digest_str |]) in
          log_info "Trying to add to system cache using %s" helper;
          let proc =
            U.finally_do
              (fun old_cwd -> system#chdir old_cwd)
              system#getcwd
              (fun _ ->
                system#chdir tmpdir;
                Lwt_process.open_process_none ~env ~stdin:`Dev_null command) in
          Lwt.bind proc#close (fun status ->
            try
              Support.System.check_exit_status status;
              log_info "Added succcessfully using helper.";
              Lwt.return `Success
            with Safe_exn.T _ as ex ->
              log_warning ~ex "Error running %s" helper;
              Lwt.return `No_helper
          )
        )
  )

let rec fixup_permissions (system:#filesystem) path =
  let info = system#lstat path |? lazy (Safe_exn.failf "Path '%s' has disappeared!" path) in
  match info.Unix.st_kind with
  | Unix.S_LNK -> ()
  | Unix.S_DIR | Unix.S_REG ->
      let mode = info.Unix.st_perm in
      if mode land 0o777 <> mode then (
        Safe_exn.failf "Unsafe mode: extracted file '%s' had special bits set in mode '%o'" path mode
      );
      let desired_mode = if (mode land 0o111) <> 0 || info.Unix.st_kind = Unix.S_DIR then 0o555 else 0o444 in
      if mode <> desired_mode then
        system#chmod path desired_mode;

      if info.Unix.st_kind = Unix.S_DIR then (
        match system#readdir path with
        | Error ex -> raise ex
        | Ok items ->
            items |> Array.iter (fun item ->
              fixup_permissions system (path +/ item)
            )
      )
  | _ -> Safe_exn.failf "Not a regular file/directory/symlink '%s'" path

let add_manifest_and_verify system required_digest tmpdir =
  let (alg, required_value) = required_digest in
  let actual_value = Manifest.add_manifest_file system alg tmpdir in
  if (actual_value <> required_value) then (
    Safe_exn.failf "Incorrect manifest -- archive is corrupted.\n\
                Required digest: %s\n\
                Actual digest: %s" (Manifest.format_digest required_digest) (Manifest.format_digest (alg, actual_value))
  )

(** Check that [tmpdir] has the required_digest and move it into the stores. On success, [tmpdir] no longer exists. *)
let check_manifest_and_rename config required_digest tmpdir =
  (* We try to add the implementation in three ways:
   * 1. Writing directly to the system store (will succeed if we're root)
   * 2. Using the helper to write to the system store
   * 3. Writing directly to the user store *)
  fixup_permissions config.system tmpdir;
  add_manifest_and_verify config.system required_digest tmpdir;
  match config.stores with
  | [] -> Safe_exn.failf "No stores configured!"
  | [user_store] -> add_to_store config user_store required_digest tmpdir; Lwt.return ()
  | user_store :: system_store :: _ ->
      try
        add_to_store config system_store required_digest tmpdir;
        Lwt.return ()
      with Unix.Unix_error (Unix.EACCES, _, _) | Unix.Unix_error (Unix.EROFS, _, _) ->
        Lwt.bind (add_with_helper config required_digest tmpdir) (function
          | `Success -> U.rmtree config.system ~even_if_locked:true tmpdir; Lwt.return ()
          | `No_helper -> add_to_store config user_store required_digest tmpdir; Lwt.return ()
        )

(** Like [check_manifest_and_rename], but copies [dir] rather than renaming it. *)
let add_dir_to_cache config required_digest dir =
  let tmpdir = make_tmp_dir config.system config.stores in
  try
    copy_tree config.system dir tmpdir;
    check_manifest_and_rename config required_digest tmpdir
  with ex ->
    U.rmtree ~even_if_locked:true config.system tmpdir;
    raise ex
