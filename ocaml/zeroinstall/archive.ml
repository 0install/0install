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

type compression = Bzip2 | Gzip | Lzma | Xz | Uncompressed

let make_command = U.make_command

(** Run a command in a subprocess. If it returns an error code, generate an exception containing its stdout and stderr. *)
let run_command ?cwd system args =
  (* Some zip archives are missing timezone information; force consistent results *)
  let child_env = Array.append system#environment [|
    (* Some zip archives lack time-zone information. Make sure all systems see the same time. *)
    "TZ=GMT";

    (* Stop OS X extracting extended attributes: *)
    "COPYFILE_DISABLE=true";                    (* Leopard *)
    "COPY_EXTENDED_ATTRIBUTES_DISABLE=true";    (* Tiger *)
  |] in

  (* todo: use pola-run if available, once it supports fchmod *)
  let command = make_command system args in
  let child =
    match cwd with
    | None -> Lwt_process.open_process_full ~env:child_env command
    | Some cwd ->
        U.finally_do
          (fun old_cwd -> system#chdir old_cwd)
          system#getcwd
          (fun _ ->
            system#chdir cwd;
            Lwt_process.open_process_full ~env:child_env command) in
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

let re_gnu_tar = Str.regexp ".*(GNU tar)"
let _tar_flavour = ref `unknown
let get_tar_flavour system =
  match !_tar_flavour with
  | `unknown ->
      lwt line = Lwt_process.pread_line (make_command system ["tar"; "--version"]) in
      let f =
        if Str.string_match re_gnu_tar line 0 then `gnu_tar
        else `plain_tar in
      _tar_flavour := f;
      Lwt.return f
  | (`gnu_tar | `plain_tar) as x -> Lwt.return x

let extract_tar config ~dstdir ?extract ~compression archive =
  let system = config.system in

  extract |> if_some (fun extract ->
    (* Limit the characters we accept, to avoid sending dodgy strings to tar *)
    if not (Str.string_match (Str.regexp "^[a-zA-Z0-9][- _a-zA-Z0-9.]*$") extract 0) then
      raise_safe "Illegal character in extract attribute ('%s')" extract
  );

  let share_dir = lazy (
    let bindir = Filename.dirname config.abspath_0install in
    let sys_share = bindir +/ ".." +/ "share" in
    if U.is_dir system sys_share then sys_share   (* 0install is installed as distro package *)
    else bindir +/ "share"                        (* Running via 0install *)
  ) in

  lwt tar_flavour = get_tar_flavour system in

  let ext_cmd = ["tar"; "-xf"; archive; "-C"; dstdir] @

    begin match tar_flavour with
    | `gnu_tar -> ["--no-same-owner"; "--no-same-permissions"]
    | `plain_tar -> [] end @

    begin match compression with
    | Bzip2 -> ["--bzip2"]
    | Gzip -> ["-z"]
    | Lzma ->
        let unlzma = U.find_in_path system "unlzma" |? lazy (
          Lazy.force share_dir +/ "0install.net" +/ "unlzma"
        ) in ["--use-compress-program=" ^ unlzma]
    | Xz ->
        let unxz = U.find_in_path system "unxz" |? lazy (
          Lazy.force share_dir +/ "0install.net" +/ "unxz"
        ) in ["--use-compress-program=" ^ unxz]
    | Uncompressed -> [] end @

    begin match extract with
    | Some extract -> [extract]
    | None -> [] end in

  run_command system ext_cmd

let extract_gem config ~dstdir ?extract archive =
  let payload = "data.tar.gz" in
  let tmpdir = U.make_tmp_dir config.system ~prefix:"extract-gem-" dstdir in
  try_lwt
    (archive |> extract_tar config ~dstdir:tmpdir ~extract:payload ~compression:Uncompressed) >>
    (tmpdir +/ payload |> extract_tar config ~dstdir ?extract ~compression:Gzip);
  finally
    U.rmtree ~even_if_locked:true config.system tmpdir;
    Lwt.return ()

let extract_cab config ~dstdir ?extract archive =
  extract |> if_some (fun _ -> raise_safe "Sorry, but the 'extract' attribute is not yet supported for Cabinet files");
  run_command config.system ["cabextract"; "-s"; "-q"; "-d"; dstdir; archive]

let extract_dmg config ~dstdir ?extract archive =
  extract |> if_some (fun _ -> raise_safe "Sorry, but the 'extract' attribute is not yet supported for DMGs");

  let system = config.system in

  let mountpoint = U.make_tmp_dir system ~prefix:"archive-" dstdir in

  lwt () = run_command system ["hdiutil"; "attach"; "-quiet"; "-mountpoint"; mountpoint; "-nobrowse"; archive] in
  lwt () =
    Lwt.finalize (fun () ->
      let files =
        match system#readdir mountpoint with
        | Problem ex -> raise ex
        | Success items -> Array.to_list items |> List.map ((^) (mountpoint ^ "/")) in
      run_command system @@ ["cp"; "-pR"] @ files @ [dstdir]
    ) (fun () ->
      run_command system @@ ["hdiutil"; "detach"; "-quiet"; mountpoint]
    ) in
  U.rmtree ~even_if_locked:true system mountpoint;
  Lwt.return ()

let extract_deb config ~dstdir ?extract archive =
  extract |> if_some (fun _ -> raise_safe "Sorry, but the 'extract' attribute is not yet supported for Debs");
  let system = config.system in
  lwt output = Lwt_process.pread (make_command system ["ar"; "t"; archive ]) in
  let rec get_type stream =
    try
      let name = Stream.next stream in
      match name with
      | "data.tar" -> (name, Uncompressed)
      | "data.tar.gz" -> (name, Gzip)
      | "data.tar.bz2" -> (name, Bzip2)
      | "data.tar.lzma" -> (name, Lzma)
      | "data.tar.xz" -> (name, Xz)
      | _ -> get_type stream
    with Stream.Failure -> raise_safe "File is not a Debian package." in
  let data_tar, compression = get_type (U.stream_of_lines output) in

  lwt () = run_command system ~cwd:dstdir ["ar"; "x"; archive; data_tar] in
  let data_path = dstdir +/ data_tar in
  lwt () = data_path |> extract_tar config ~dstdir ~compression in
  system#unlink data_path;
  Lwt.return ()

let extract_rpm config ~dstdir ?extract archive =
  extract |> if_some (fun _ -> raise_safe "Sorry, but the 'extract' attribute is not yet supported for RPMs");
  let system = config.system in
  let r, w = Unix.pipe () in
  let rpm2cpio, cpio =
    U.finally_do
      (fun old_cwd -> system#chdir old_cwd)
      system#getcwd
      (fun _ ->
        system#chdir dstdir;
        let rpm2cpio = Lwt_process.exec ~stdout:(`FD_move w) @@ make_command system ["rpm2cpio"; archive] in
        let cpio = Lwt_process.exec ~stdin:(`FD_move r) ~stderr:`Dev_null @@ make_command system ["cpio"; "-mid"] in
        (rpm2cpio, cpio)
      ) in
  lwt rpm2cpio = rpm2cpio
  and cpio = cpio in
  Support.System.check_exit_status rpm2cpio;
  Support.System.check_exit_status cpio;

  (* Set the mtime of every directory under 'tmp' to 0, since cpio doesn't
     preserve directory mtimes. *)
  let rec set_mtimes dir =
    system#set_mtime dir 0.0;
    match system#readdir dir with
    | Problem ex -> raise ex
    | Success items ->
        items |> Array.iter (fun item ->
          let path = dir +/ item in
          if U.is_dir system path then set_mtimes path
        ) in
  set_mtimes dstdir;
  Lwt.return ()

let extract_zip config ~dstdir ?extract archive =
  extract |> if_some (fun extract ->
    (* Limit the characters we accept, to avoid sending dodgy strings to zip *)
    if not (Str.string_match (Str.regexp "^[a-zA-Z0-9][- _a-zA-Z0-9.]*$") extract 0) then
      raise_safe "Illegal character in extract attribute"
  );
  let args = ["unzip"; "-q"; "-o"; archive] in
  match extract with
  | None -> run_command ~cwd:dstdir config.system args
  | Some extract -> run_command ~cwd:dstdir config.system (args @ [extract ^ "/*"])

(** Unpack [tmpfile] into directory [dstdir]. If [extract] is given, extract just
    that sub-directory from the archive (i.e. destdir/extract will exist afterwards). *)
let unpack config tmpfile dstdir ?extract ~mime_type : unit Lwt.t =
  let tmpfile = U.abspath config.system tmpfile in
  match mime_type with
  | "application/x-tar" ->                  tmpfile |> extract_tar config ~dstdir ?extract ~compression:Uncompressed
  | "application/x-compressed-tar" ->       tmpfile |> extract_tar config ~dstdir ?extract ~compression:Gzip
  | "application/x-bzip-compressed-tar" ->  tmpfile |> extract_tar config ~dstdir ?extract ~compression:Bzip2
  | "application/x-ruby-gem" ->             tmpfile |> extract_gem config ~dstdir ?extract
  | "application/vnd.ms-cab-compressed" ->  tmpfile |> extract_cab config ~dstdir ?extract 
  | "application/x-apple-diskimage" ->      tmpfile |> extract_dmg config ~dstdir ?extract 
  | "application/x-deb" ->                  tmpfile |> extract_deb config ~dstdir ?extract 
  | "application/x-rpm" ->                  tmpfile |> extract_rpm config ~dstdir ?extract 
  | "application/zip" ->                    tmpfile |> extract_zip config ~dstdir ?extract 
  | "application/x-lzma-compressed-tar" ->  tmpfile |> extract_tar config ~dstdir ?extract ~compression:Lzma
  | "application/x-xz-compressed-tar" ->    tmpfile |> extract_tar config ~dstdir ?extract ~compression:Xz
  | _ -> raise_safe "Unknown MIME type '%s'" mime_type

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

let unpack_over ?extract config ~archive ~tmpdir ~destdir ~mime_type =
  let system = config.system in
  extract |> if_some (fun extract ->
    if Str.string_match (Str.regexp ".*[/\\]") extract 0 then
      raise_safe "Extract attribute may not contain / or \\ (got '%s')" extract
  );
  let tmp = U.make_tmp_dir system ~prefix:"0install-unpack-" tmpdir in
  try_lwt
    lwt () = unpack config ?extract ~mime_type archive tmp in

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
