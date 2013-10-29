(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common

module H = Support.Hash
module U = Support.Utils

let generate_manifest ~old (system:system) hash_name root =
  let manifest = Buffer.create 1000 in

  let rec loop sub =
    (* To ensure that a line-by-line comparison of the manifests
       is possible, we require that filenames don't contain newlines.
       Otherwise, you could name a file so that the part after the \n
       would be interpreted as another line in the manifest. *)
    if String.contains sub '\n' then raise_safe "Newline in filename '%s'" sub;
    assert (sub.[0] = '/');

    let rel_path = U.string_tail sub 1 in
    let full = root +/ rel_path in

    if rel_path <> "" then (
      Buffer.add_string manifest "D ";
      if old then (
        let info = system#lstat full |? lazy (raise_safe "File '%s' no longer exists!" full) in
        Buffer.add_string manifest (Int64.of_float info.Unix.st_mtime |> Int64.to_string);
        Buffer.add_char manifest ' ';
      );
      Buffer.add_string manifest sub;
      Buffer.add_char manifest '\n';
    );
    let items =
      match system#readdir full with
      | Problem ex -> raise ex
      | Success items -> items in
    Array.sort String.compare items;

    let dirs = U.filter_map_array items ~f:(fun leaf ->
      let path = root +/ rel_path +/ leaf in
      let info = system#lstat path |? lazy (raise_safe "File '%s' no longer exists!" path) in
      match info.Unix.st_kind with
      | Unix.S_REG when leaf = ".manifest" && rel_path = "" -> None
      | Unix.S_REG ->
          let d = H.create hash_name in
          system#with_open_in [Open_rdonly; Open_binary] 0 path (H.update_from_channel d);
          let hex_digest = H.hex_digest d in

          if (info.Unix.st_perm land 0o111) <> 0 then
            Buffer.add_string manifest "X "
          else
            Buffer.add_string manifest "F ";

          Buffer.add_string manifest hex_digest;
          Buffer.add_char manifest ' ';
          Buffer.add_string manifest (Int64.of_float info.Unix.st_mtime |> Int64.to_string);
          Buffer.add_char manifest ' ';
          Buffer.add_string manifest (string_of_int info.Unix.st_size);
          Buffer.add_char manifest ' ';
          Buffer.add_string manifest leaf;
          Buffer.add_char manifest '\n';
          None
      | Unix.S_LNK ->
          let target = system#readlink path |? lazy (raise_safe "Failed to read symlink '%s'" path) in
          let d = H.create hash_name in
          H.update d target;
          (* Note: Can't use utime on symlinks, so skip mtime *)
          Buffer.add_string manifest "S ";
          Buffer.add_string manifest (H.hex_digest d);
          Buffer.add_char manifest ' ';
          (* Note: eCryptfs may report length as zero, so count ourselves instead *)
          Buffer.add_string manifest (string_of_int (String.length target));
          Buffer.add_char manifest ' ';
          Buffer.add_string manifest leaf;
          Buffer.add_char manifest '\n';
          None
      | Unix.S_DIR ->
          if old then (
            let sub = if rel_path = "" then sub else sub ^ "/" in
            loop (sub ^ leaf); None
          ) else Some leaf
      | _ -> raise_safe "Not a regular file/directory/symlink '%s'" path
    ) in

    let sub = if rel_path = "" then sub else sub ^ "/" in
    dirs |> List.iter (fun x ->
      (* Note: "sub" is always Unix style. Don't use +/ here. *)
      loop (sub ^ x)
    ) in

  loop "/";
  Buffer.contents manifest

(** Writes a .manifest file into 'dir', and returns the digest.
    You should call Stores.fixup_permissions before this to ensure that the permissions are correct.
    On exit, dir itself has mode 555. Subdirectories are not changed. *)
let add_manifest_file system alg dir =
  try
    let mfile = dir +/ ".manifest" in
    if system#lstat mfile <> None then  (* lstat to cope with symlinks *)
      raise_safe "Directory '%s' already contains a .manifest file!" dir;

    let hash_name, generate =
      match alg with
      | "sha1" -> ("sha1", generate_manifest ~old:true)
      | "sha1new" -> ("sha1", generate_manifest ~old:false)
      | "sha256" | "sha256new" -> ("sha256", generate_manifest ~old:false)
      | _ -> raise_safe "Unknown manifest digest algorithm '%s'" alg in

    let manifest_contents = generate system hash_name dir in
    let digest = H.create hash_name in
    H.update digest manifest_contents;

    system#chmod dir 0o755;
    system#atomic_write [Open_wronly; Open_binary] mfile ~mode:0o444 (fun ch ->
      output_string ch manifest_contents
    );
    system#chmod dir 0o555;
    match alg with
    | "sha1" | "sha1new" | "sha256" -> H.hex_digest digest
    | _ ->
        (* Base32-encode newer algorithms to make the digest shorter.
           We can't use base64 as Windows is case insensitive.
           There's no need for padding (and = characters in paths cause problems for some software). *)
        H.b32_digest digest
  with Safe_exception _ as ex -> reraise_with_context ex "... adding .manifest file in %s" dir

let get_algorithm_names () = [
    "sha1";
    "sha1new";
    "sha256";
    "sha256new";
  ]
