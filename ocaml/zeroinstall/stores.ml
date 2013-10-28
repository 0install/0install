(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Managing cached implementations *)

open General
open Support.Common
module U = Support.Utils

type stores = string list

type digest = (string * string)

type available_digests = (string, filepath) Hashtbl.t

exception Not_stored of string

let first_match = Support.Utils.first_match

let format_digest (alg, value) =
  let s = match alg with
  | "sha1" | "sha1new" | "sha256" -> alg ^ "=" ^ value
  | _ -> alg ^ "_" ^ value in
  (* validate *)
  s

let lookup_digest (system:system) stores digest =
  let check_store store = (
    let path = Filename.concat store (format_digest digest) in
    if system#file_exists path then Some path else None
  ) in first_match ~f:check_store stores

let lookup_maybe system digests stores = first_match ~f:(lookup_digest system stores) digests

let lookup_any system digests stores =
  match lookup_maybe system digests stores with
  | Some path -> path
  | None ->
      let str_digests = String.concat ", " (List.map format_digest digests) in
      let str_stores = String.concat ", " stores in
      raise (Not_stored ("Item with digests " ^ str_digests ^ " not found in stores. Searched " ^ str_stores))

let get_default_stores basedir_config =
  let open Support.Basedir in
  List.map (fun prefix -> prefix +/ "0install.net" +/ "implementations") basedir_config.cache

let get_available_digests (system:system) stores =
  let digests = Hashtbl.create 1000 in
  let scan_dir dir =
    match system#readdir dir with
    | Success items ->
        for i = 0 to Array.length items - 1 do
          Hashtbl.add digests items.(i) dir
        done
    | Problem _ -> log_debug "Can't scan %s" dir
    in
  List.iter scan_dir stores;
  digests

let check_available available_digests digests =
  List.exists (fun d -> Hashtbl.mem available_digests (format_digest d)) digests

let get_digests elem =
  let id = ZI.get_attribute "id" elem in
  let init = match Str.bounded_split_delim U.re_equals id 2 with
  | [key; value] when key = "sha1" || key = "sha1new" || key = "sha256" -> [(key, value)]
  | _ -> [] in

  let check_attr init ((ns, name), value) = match ns with
    | "" -> (name, value) :: init
    | _ -> init in
  let extract_digests init elem =
    List.fold_left check_attr init elem.Support.Qdom.attrs in
  ZI.fold_left ~f:extract_digests init elem "manifest-digest"

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
      raise_safe "None of the candidate digest algorithms (%s) is supported" algs

let make_tmp_dir (system:system) = function
  | store :: _ ->
      U.makedirs system store 0o755;
      let mode = 0o755 in     (* r-x for all; needed by 0store-helper *)
      U.make_tmp_dir system ~mode store
  | _ -> raise_safe "No stores configured!"

(** Copy the contents of [srcdir] into [dstdir] (which must be empty).
 * Permissions on the new copies will be 555 or 444. mtimes are copied. *)
let rec copy_tree system srcdir dstdir =
  match system#readdir srcdir with
  | Problem ex -> raise ex
  | Success items ->
      items |> Array.iter (fun item ->
        assert (item <> "." && item <> "..");

        let src_path = srcdir +/ item in
        let dst_path = dstdir +/ item in
        let src_info = system#lstat src_path |? lazy (raise_safe "Path '%s' has disappeared!" src_path) in

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
            let linkto = system#readlink src_path |? lazy (raise_safe "Failed to read symlink target '%s'" src_path) in
            system#symlink ~target:linkto ~newlink:dst_path
        | _ -> raise_safe "Not a regular file/directory/symlink '%s'" src_path end;
      )

(** Rename or move [tmpdir] as [store]/[digest]. The digest is not checked here. *)
let add_to_store config store digest tmpdir =
  U.makedirs config.system store 0o755;
  let path = store +/ (format_digest digest) in
  if config.dry_run then (
    Dry_run.log "would store implementation as %s" path;
    config.system#mkdir path 0o755;
    U.rmtree ~even_if_locked:true config.system#bypass_dryrun tmpdir;
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
  if fst required_digest = "sha1" then Lwt.return `no_helper     (* Old digest alg not supported *)
  else if system#getenv "ZEROINSTALL_PORTABLE_BASE" <> None then Lwt.return `no_helper  (* Can't use helper with portable mode *)
  else (
    match U.find_in_path system "0store-secure-add-helper" with
    | None -> log_info "'0store-secure-add-helper' command not found. Not adding to system cache."; Lwt.return `no_helper
    | Some helper ->
        let digest_str = format_digest required_digest in
        if config.dry_run then (
          Dry_run.log "would use %s to store %s in system store" helper digest_str; Lwt.return `success
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
              Lwt.return `success
            with Safe_exception _ as ex ->
              log_warning ~ex "Error running %s" helper;
              Lwt.return `no_helper
          )
        )
  )

let add_manifest_and_verify (slave:Python.slave) required_digest tmpdir =
  let request = `List [
    `String "add-manifest-and-verify";
    `String (format_digest required_digest);
    `String tmpdir] in
  slave#invoke_async request Python.expect_null

(** Check that [tmpdir] has the required_digest and move it into the stores. On success, [tmpdir] no longer exists. *)
let check_manifest_and_rename config (slave:Python.slave) required_digest tmpdir =
  (* We try to add the implementation in three ways:
   * 1. Writing directly to the system store (will succeed if we're root)
   * 2. Using the helper to write to the system store
   * 3. Writing directly to the user store *)
  let rq = add_manifest_and_verify slave required_digest tmpdir in
  Lwt.bind rq (fun () ->
    begin match config.stores with
    | [] -> raise_safe "No stores configured!"
    | [user_store] -> add_to_store config user_store required_digest tmpdir; Lwt.return ()
    | user_store :: system_store :: _ ->
        try
          add_to_store config system_store required_digest tmpdir;
          Lwt.return ()
        with Unix.Unix_error (Unix.EACCES, _, _) ->
          Lwt.bind (add_with_helper config required_digest tmpdir) (function
            | `success -> U.rmtree config.system ~even_if_locked:true tmpdir; Lwt.return ()
            | `no_helper -> add_to_store config user_store required_digest tmpdir; Lwt.return ()
          )
    end
  )
