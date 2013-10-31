(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
open Support.Common
module U = Support.Utils

type mime_type = string

let type_from_url url =
  let re_extension = Str.regexp "\\(\\.tar\\)?\\.[^./]+$" in
  let ext =
    try U.string_tail url @@ Str.search_forward re_extension url 0
    with Not_found -> "" in
  match String.lowercase ext with
  | ".tar.bz2"  -> "application/x-bzip-compressed-tar"
  | ".tar.gz"   -> "application/x-compressed-tar"
  | ".tar.lzma" -> "application/x-lzma-compressed-tar"
  | ".tar.xz"   -> "application/x-xz-compressed-tar"
  | ".rpm" -> "application/x-rpm"
  | ".deb" -> "application/x-deb"
  | ".tbz" -> "application/x-bzip-compressed-tar"
  | ".tgz" -> "application/x-compressed-tar"
  | ".tlz" -> "application/x-lzma-compressed-tar"
  | ".txz" -> "application/x-xz-compressed-tar"
  | ".tar" -> "application/x-tar"
  | ".zip" -> "application/zip"
  | ".cab" -> "application/vnd.ms-cab-compressed"
  | ".dmg" -> "application/x-apple-diskimage"
  | ".gem" -> "application/x-ruby-gem"
  | _ -> raise_safe "Can't guess MIME type from name (%s)" url

let check_type_ok system =
  let missing name = U.find_in_path system name = None in
  function
    | "application/x-rpm" -> if missing "rpm2cpio" then
        raise_safe "This package looks like an RPM, but you don't have the rpm2cpio command \
                    I need to extract it. Install the \"rpm\" package first (this works even if \
                    you're on a non-RPM-based distribution such as Debian)."
    | "application/x-deb" -> if missing "ar" then
        raise_safe "This package looks like a Debian package, but you don't have the \"ar\" command \
                     I need to extract it. Install the package containing it (sometimes called \"binutils\") \
                     first. This works even if you're on a non-Debian-based distribution such as Red Hat)."
    | "application/x-bzip-compressed-tar" -> ()	(* We"ll fall back to Python"s built-in tar.bz2 support *)
    | "application/zip" -> if missing "unzip" then
        raise_safe "This package looks like a zip-compressed archive, but you don't have the \"unzip\" command \
                    I need to extract it. Install the package containing it first."
    | "application/vnd.ms-cab-compressed" -> if missing "cabextract" then
        raise_safe "This package looks like a Microsoft Cabinet archive, but you don't have the \"cabextract\" command \
                    I need to extract it. Install the package containing it first."
    | "application/x-apple-diskimage" -> if missing "hdiutil" then
        raise_safe "This package looks like a Apple Disk Image, but you don't have the \"hdiutil\" command \
                    I need to extract it."
    | "application/x-lzma-compressed-tar" -> () (* We can get it through Zero Install *)
    | "application/x-xz-compressed-tar" -> if missing "unxz" then
        raise_safe "This package looks like a xz-compressed package, but you don't have the \"unxz\" command \
                    I need to extract it. Install the package containing it (it's probably called \"xz-utils\") first."
    | "application/x-compressed-tar" | "application/x-tar" | "application/x-ruby-gem" -> ()
    | mime_type ->
        raise_safe "Unsupported archive type \"%s\" (for 0install version %s)" mime_type About.version

let maybe = function
  | Some v -> `String v
  | None -> `Null

type compression = Bzip2 | Gzip | Lzma | Xz | Uncompressed

let () = ignore (Lzma, Xz)

(** Run a command in a subprocess. If it returns an error code, generate an exception containing its stdout and stderr. *)
let run_command system args =
  (* Some zip archives are missing timezone information; force consistent results *)
  let child_env = Array.append system#environment [| "TZ=GMT" |] in

  (* todo: use pola-run if available, once it supports fchmod *)
  let command = (U.find_in_path_ex system (List.hd args), Array.of_list args) in
  let child = Lwt_process.open_process_full ~env:child_env command in
  try_lwt
    lwt stdout = Lwt_io.read child#stdout
    and stderr = Lwt_io.read child#stderr
    and () = Lwt_io.close child#stdin in

    lwt status = child#close in

    try
      match status with
      | Unix.WEXITED 0 -> Lwt.return ()
      | status ->
          let messages = trim @@ stdout ^ stderr in
          if messages = "" then Support.System.check_exit_status status;
          raise_safe "Command failed: %s" messages
    with Safe_exception _ as ex ->
      reraise_with_context ex "... extracting archive with: %s" (Support.Logging.format_argv_for_logging args)
  finally
    lwt _ = child#close in
    Lwt.return ()

let extract_tar config ~dstdir ?extract ~compression archive =
  let system = config.system in

  extract |> if_some (fun extract ->
    (* Limit the characters we accept, to avoid sending dodgy strings to tar *)
    if not (Str.string_match (Str.regexp "^[a-zA-Z0-9][- _a-zA-Z0-9.]*$") extract 0) then
      raise_safe "Illegal character in extract attribute"
  );

  let ext_cmd = ["tar"; "-xf"; archive; "--no-same-owner"; "--no-same-permissions"; "-C"; dstdir] @

    begin match compression with
    | Bzip2 -> ["--bzip2"]
    | Gzip -> ["-z"]
    | Lzma ->
        let unlzma = U.find_in_path system "unlzma" |? lazy (
          config.abspath_0install +/ "../lib/0install/_unlzma"      (* TODO - testme *)
        ) in ["--use-compress-program=" ^ unlzma]
    | Xz ->
        let unxz = U.find_in_path system "unxz" |? lazy (
          config.abspath_0install +/ "../lib/0install/_unxz"        (* TODO - testme *)
        ) in ["--use-compress-program=" ^ unxz]
    | Uncompressed -> [] end @

    begin match extract with
    | Some extract -> [extract]
    | None -> [] end in

  run_command system ext_cmd

(** Unpack [tmpfile] into directory [dstdir]. If [extract] is given, extract just
    that sub-directory from the archive (i.e. destdir/extract will exist afterwards). *)
let unpack config (slave:Python.slave) tmpfile dstdir ?extract ~mime_type : unit Lwt.t =
  match mime_type with
  | "application/x-tar" ->                  extract_tar config ~dstdir ?extract ~compression:Uncompressed tmpfile
  | "application/x-compressed-tar" ->       extract_tar config ~dstdir ?extract ~compression:Gzip tmpfile
  | "application/x-bzip-compressed-tar" ->  extract_tar config ~dstdir ?extract ~compression:Bzip2 tmpfile
(*
  | "application/x-deb" ->                  extract_deb tmpfile dstdir ~start_offset ~extract 
  | "application/x-rpm" ->                  extract_rpm tmpfile dstdir ~start_offset ~extract 
  | "application/zip" ->                    extract_zip tmpfile dstdir ~start_offset ~extract 
  | "application/x-lzma-compressed-tar" ->  extract_tar tmpfile dstdir ~start_offset ~extract (Some "lzma")
  | "application/x-xz-compressed-tar" ->    extract_tar tmpfile dstdir ~start_offset ~extract (Some "xz")
  | "application/vnd.ms-cab-compressed" ->  extract_cab tmpfile dstdir ~start_offset ~extract 
  | "application/x-apple-diskimage" ->      extract_dmg tmpfile dstdir ~start_offset ~extract 
  | "application/x-ruby-gem" ->             extract_gem tmpfile dstdir ~start_offset ~extract 
  | _ -> raise_safe "Unknown MIME type '%s'" mime_type
*)
  | _ ->
      let request = `List [`String "unpack-archive"; `Assoc [
        ("tmpfile", `String tmpfile);
        ("destdir", `String dstdir);
        ("extract", maybe extract);
        ("start_offset", `Float 0.0);
        ("mime_type", `String mime_type);
      ]] in
      slave#invoke_async request (function
        | `Null -> ()
        | json -> raise_safe "Invalid JSON response '%s'" (Yojson.Basic.to_string json)
      )

(** Move each item in [srcdir] into [dstdir]. Symlinks are copied as is. Does not follow any symlinks in [destdir]. *)
let rec move_no_follow system srcdir dstdir =
  match system#readdir srcdir with
  | Problem ex -> raise ex
  | Success items ->
      items |> Array.iter (fun item ->
        assert (item <> "." && item <> "..");

        let src_path = srcdir +/ item in
        let dst_path = dstdir +/ item in
        let src_info = system#lstat src_path |? lazy (raise_safe "Path '%s' has disappeared!" src_path) in
        let dst_info = system#lstat dst_path in

        match src_info.Unix.st_kind with
        | Unix.S_DIR ->
            begin match dst_info with
            | None -> system#mkdir dst_path 0o755
            | Some info when info.Unix.st_kind = Unix.S_DIR -> ()
            | Some _ -> raise_safe "Attempt to unpack dir over non-directory '%s'" item end;
            move_no_follow system src_path dst_path;
            system#rmdir src_path;
            system#set_mtime dst_path src_info.Unix.st_mtime
        | Unix.S_REG | Unix.S_LNK ->
            begin match dst_info with
            | None -> ()
            | Some info when info.Unix.st_kind = Unix.S_DIR -> raise_safe "Can't replace directory '%s' with file '%s'" item src_path
            | Some _ -> system#unlink dst_path end;
            system#rename src_path dst_path
        | _ -> raise_safe "Not a regular file/directory/symlink '%s'" src_path
      )

let unpack_over ?extract config slave ~archive ~tmpdir ~destdir ~mime_type =
  let system = config.system in
  extract |> if_some (fun extract ->
    if Str.string_match (Str.regexp ".*[/\\]") extract 0 then
      raise_safe "Extract attribute may not contain / or \\ (got '%s')" extract
  );
  let tmp = U.make_tmp_dir system ~prefix:"0install-unpack-" tmpdir in
  try_lwt
    lwt () = unpack config slave ?extract ~mime_type archive tmp in

    let srcdir =
      match extract with
      | None -> tmp
      | Some extract ->
          let srcdir = tmp +/ extract in
          if U.is_dir system srcdir then srcdir
          else raise_safe "Top-level directory '%s' not found in archive" extract in

    move_no_follow system srcdir destdir;
    Lwt.return ()
  finally
    U.rmtree ~even_if_locked:true system tmp;
    Lwt.return ()
