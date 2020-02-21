(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
open Support.Common

module H = Support.Hash
module U = Support.Utils

type alg = string
type digest = string * string

let format_digest (alg, value) =
  let s = match alg with
  | "sha1" | "sha1new" | "sha256" -> alg ^ "=" ^ value
  | _ -> alg ^ "_" ^ value in
  (* validate *)
  s

let strict_digest_prefixes = ["sha1="; "sha1new="; "sha256="; "sha256new_"]
let lenient_digest_prefixes = "sha256new=" :: strict_digest_prefixes

let parse_digest_from prefixes digest =
  prefixes |> U.first_match (fun prefix ->
    if XString.starts_with digest prefix then (
      let alg = String.sub prefix 0 (String.length prefix - 1) in
      let value = XString.tail digest (String.length prefix) in
      Some (alg, value)
    ) else None
  ) |? lazy (Safe_exn.failf "Unknown digest type '%s'" digest)

let parse_digest = parse_digest_from strict_digest_prefixes
let parse_digest_loose = parse_digest_from lenient_digest_prefixes

let generate_manifest (system:#filesystem) alg root =
  let old = (alg = "sha1") in
  let hash_name =
    match alg with
    | "sha1" | "sha1new" -> "sha1"
    | "sha256" | "sha256new" -> "sha256"
    | _ -> Safe_exn.failf "Unknown manifest digest algorithm '%s'" alg in

  let manifest = Buffer.create 1000 in

  let rec loop sub =
    (* To ensure that a line-by-line comparison of the manifests
       is possible, we require that filenames don't contain newlines.
       Otherwise, you could name a file so that the part after the \n
       would be interpreted as another line in the manifest. *)
    if String.contains sub '\n' then Safe_exn.failf "Newline in filename '%s'" sub;
    assert (sub.[0] = '/');

    let rel_path = XString.tail sub 1 in
    let full = root +/ rel_path in

    if rel_path <> "" then (
      Buffer.add_string manifest "D ";
      if old then (
        let info = system#lstat full |? lazy (Safe_exn.failf "File '%s' no longer exists!" full) in
        Buffer.add_string manifest (Int64.of_float info.Unix.st_mtime |> Int64.to_string);
        Buffer.add_char manifest ' ';
      );
      Buffer.add_string manifest sub;
      Buffer.add_char manifest '\n';
    );
    let items =
      match system#readdir full with
      | Error ex -> raise ex
      | Ok items -> items in
    Array.sort String.compare items;

    let dirs = items |> U.filter_map_array (fun leaf ->
      let path = root +/ rel_path +/ leaf in
      let info = system#lstat path |? lazy (Safe_exn.failf "File '%s' no longer exists!" path) in
      match info.Unix.st_kind with
      | Unix.S_REG when leaf = ".manifest" && rel_path = "" -> None
      | Unix.S_REG ->
          let d = H.create hash_name in
          path |> system#with_open_in [Open_rdonly; Open_binary] (H.update_from_channel d);
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
          let target = system#readlink path |? lazy (Safe_exn.failf "Failed to read symlink '%s'" path) in
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
      | _ -> Safe_exn.failf "Not a regular file/directory/symlink '%s'" path
    ) in

    let sub = if rel_path = "" then sub else sub ^ "/" in
    dirs |> List.iter (fun x ->
      (* Note: "sub" is always Unix style. Don't use +/ here. *)
      loop (sub ^ x)
    ) in

  loop "/";
  Buffer.contents manifest

(** Generate the final overall hash of the manifest. *)
let hash_manifest alg manifest_contents =
  let hash_name =
    match alg with
    | "sha1" | "sha1new" -> "sha1"
    | "sha256" | "sha256new" -> "sha256"
    | _ -> Safe_exn.failf "Unknown manifest digest algorithm '%s'" alg in
  let digest = H.create hash_name in
  H.update digest manifest_contents;
  match alg with
  | "sha1" | "sha1new" | "sha256" -> H.hex_digest digest
  | _ ->
      (* Base32-encode newer algorithms to make the digest shorter.
         We can't use base64 as Windows is case insensitive.
         There's no need for padding (and = characters in paths cause problems for some software). *)
      H.b32_digest digest

let add_manifest_file system alg dir =
  try
    let mfile = dir +/ ".manifest" in
    if system#lstat mfile <> None then  (* lstat to cope with symlinks *)
      Safe_exn.failf "Directory '%s' already contains a .manifest file!" dir;

    let manifest_contents = generate_manifest system alg dir in

    system#chmod dir 0o755;
    mfile |> system#atomic_write [Open_wronly; Open_binary] ~mode:0o444 (fun ch ->
      output_string ch manifest_contents
    );
    system#chmod dir 0o555;
    hash_manifest alg manifest_contents
  with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... adding .manifest file in %s" dir

let algorithm_names = [
  "sha1";
  "sha1new";
  "sha256";
  "sha256new";
]

type hash = string
type mtime = float
type size = Int64.t

type inode =
  [ `Dir of mtime option
  | `Symlink of (hash * size)
  | `File of (bool * hash * mtime * size) ]

type manifest_dir = (filepath * tree_node) list
and tree_node =
  [ `Dir of manifest_dir
  | `Symlink of (hash * size)
  | `File of (bool * hash * mtime * size) ]

let parse_manifest_line ~old line : (string * inode) =
  let n_parts =
    match line.[0] with
    | 'D' when old -> 3
    | 'D' -> 2
    | 'S' -> 4
    | 'X' | 'F' -> 5
    | _ -> Safe_exn.failf "Malformed manifest line: '%s'" line in
  let parts = Str.bounded_split_delim XString.re_space line n_parts in
  match parts with
  | ["D"; mtime; name] when old -> (name, `Dir (Some (float_of_string mtime)))
  | ["D"; name] -> (name, `Dir None)
  | ["S"; hash; size; name] -> (name, `Symlink (hash, Int64.of_string size))
  | ["X" | "F" as ty; hash; mtime; size; name] ->
      (name, `File (ty = "X", hash, float_of_string mtime, Int64.of_string size))
  | _ -> Safe_exn.failf "Malformed manifest line: '%s'" line

(* This is really only useful for [diff].
 * We return a list of tuples (path, line), making it easy for the diff code to compare the
 * order of entries from different manifests. *)
let index_manifest ~old manifest_data =
  let dir = ref "/" in
  let items = ref [] in
  let stream = U.stream_of_lines manifest_data in
  try
    while true do
      let line = Stream.next stream in
      match parse_manifest_line ~old line with
      | (name, `Dir _) ->
          dir := name;
          items := (name, line) :: !items
      | (name, (`Symlink _ | `File _)) ->
          items := (!dir ^ "/" ^ name, line) :: !items
    done;
    assert false
  with Stream.Failure -> List.sort compare !items

let diff buffer alg aname adata bname bdata =
  Buffer.add_string buffer "- ";
  Buffer.add_string buffer aname;
  Buffer.add_string buffer "\n+ ";
  Buffer.add_string buffer bname;
  Buffer.add_string buffer "\n";

  let show ty data =
    Buffer.add_string buffer ty;
    Buffer.add_string buffer data;
    Buffer.add_char buffer '\n' in

  let rec loop adata bdata =
    match adata, bdata with
    | [], [] -> ()
    | ((_,line)::ar), [] ->
        show "- " line;
        loop ar bdata
    | [], ((_,line)::br) ->
        show "+ " line;
        loop adata br
    | ((a,aline)::ar), ((b,bline)::br) ->
        if a = b then (
          if aline <> bline then (
            show "- " aline;
            show "+ " bline;
          );
          loop ar br
        ) else if a > b then (
          show "+ " bline;
          loop adata br
        ) else (
          show "- " aline;
          loop ar bdata
        ) in
  let old = (alg = "sha1") in
  loop
    (index_manifest ~old adata)
    (index_manifest ~old bdata)

let verify system ~digest dir =
  let (alg, required_value) = digest in
  let generated_manifest = generate_manifest system alg dir in
  let generated_value = hash_manifest alg generated_manifest in

  let mfile = dir +/ ".manifest" in
  let stored_manifest =
    if system#file_exists mfile then Some (U.read_file system mfile)
    else None in
  let stored_value = stored_manifest |> pipe_some (fun m -> Some (hash_manifest alg m)) in

  if required_value = generated_value && (stored_value = None || Some generated_value = stored_value) then ()
  else (
    (* We have a problem... *)
    let b = Buffer.create 1024 in
    Buffer.add_string b (Printf.sprintf
      "Cached item does NOT verify:\n\
       %s (expected digest)\n\
       %s (actual contents)\n"
       (format_digest digest)
       (format_digest (alg, generated_value))
    );
    begin match stored_value with
    | None -> Buffer.add_char b '\n'
    | Some stored_value ->
        Buffer.add_string b @@ format_digest (alg, stored_value);
        Buffer.add_string b " (recorded in .manifest)\n\n" end;

    begin match stored_value with
    | None ->
        Buffer.add_string b "No .manifest, so no further details available."
    | Some stored_value when stored_value = generated_value ->
        Buffer.add_string b "The .manifest file matches the actual contents. Very strange!"
    | Some stored_value when stored_value = required_value ->
        Buffer.add_string b
          "The .manifest file matches the directory name.\n\
           The contents of the directory have changed:\n";
       let stored_manifest = stored_manifest |? lazy (assert false) in
       diff b alg "Recorded" stored_manifest "Actual" generated_manifest;
    | Some _ when required_value = generated_value ->
        Buffer.add_string b "The directory contents are correct, but the .manifest file is wrong!"
    | Some _ ->
        Buffer.add_string b "The .manifest file matches neither of the other digests. Odd."
    end;

    Safe_exn.failf "%s" (String.trim @@ Buffer.contents b)
  )

let parse_manifest manifest_data =
  let stream = U.stream_of_lines manifest_data in
  let rec parse_dir path =
    let items = ref [] in
    let rec collect_items () =
      Stream.peek stream |> if_some (fun line ->
        match parse_manifest_line ~old:false line with
        | (name, `Dir _) ->
            if XString.starts_with name (path ^ "/") then (
              Stream.junk stream;
              items := (Filename.basename name, `Dir (parse_dir name)) :: !items;
              collect_items ()
            ) else ()
        | (_name, (`Symlink _ | `File _)) as item ->
            items := item :: !items;
            Stream.junk stream;
            collect_items ()
      ) in
    collect_items ();
    !items in
  let items = parse_dir "" in
  begin try Stream.empty stream;
  with Stream.Failure -> failwith "BUG: more manifest items!" end;
  List.rev items

(** Copy the file [src] to [dst]. Error if it doesn't end up with the right hash. *)
let copy_with_verify (system:#filesystem) src dst ~digest ~required_hash ~mode =
  src |> system#with_open_in [Open_rdonly;Open_binary] (fun ic ->
    dst |> system#with_open_out [Open_creat;Open_excl;Open_wronly;Open_binary] ~mode (fun oc ->
      let bufsize = 4096 in
      let buf = Bytes.create bufsize in
      try
        while true do
          let got = input ic buf 0 bufsize in
          if got = 0 then raise End_of_file;
          assert (got > 0);
          let data = Bytes.sub buf 0 got |> Bytes.to_string in
          H.update digest data;
          output_string oc data
        done
      with End_of_file -> ()
    )
  );
  let actual = H.hex_digest digest in
  if actual <> required_hash then (
    system#unlink dst;
    Safe_exn.failf "Copy failed: file '%s' has wrong digest (may have been tampered with)\n\
                Expected: %s\n\
                Actual:   %s"
                src required_hash actual
  )

(** Copy each item in [req_tree] from [src_dir] to [dst_dir], checking that it matches. *)
let rec copy_subtree system hash_name req_tree src_dir dst_dir =
  req_tree |> List.iter (fun (name, inode) ->
    let src_path = src_dir +/ name in
    let dst_path = dst_dir +/ name in
    match inode with
    | `Symlink (required_hash, size) ->
        let required_size = Int64.to_int size in
        let target = system#readlink src_path |? lazy (Safe_exn.failf "Not a symlink '%s'" src_path) in
        let actual_size = String.length target in
        if actual_size <> required_size then (
          Safe_exn.failf "Symlink '%s' has wrong size (%d bytes, but should be %d according to manifest)"
            src_path actual_size required_size
        );
        let symlink_digest = H.create hash_name in
        H.update symlink_digest target;
        if H.hex_digest symlink_digest <> required_hash then (
          Safe_exn.failf "Symlink '%s' has wrong target (digest should be %s according to manifest)"
            src_path required_hash
        );
        system#symlink ~target ~newlink:dst_path
    | `Dir items ->
        system#mkdir dst_path 0o700;
        copy_subtree system hash_name items src_path dst_path;
        system#chmod dst_path 0o555;
    | `File (x, required_hash, mtime, size) ->
        match system#lstat src_path with
        | None -> Safe_exn.failf "Required source file '%s' does not exist!" src_path
        | Some info ->
            let required_size = Int64.to_int size in
            let actual_size = info.Unix.st_size in
            if actual_size <> required_size then (
              Safe_exn.failf "File '%s' has wrong size (%d bytes, but should be %d according to manifest)"
                src_path actual_size required_size
            );
            let digest = H.create hash_name in
            let mode = if x then 0o555 else 0o444 in
            copy_with_verify system src_path dst_path ~digest ~required_hash ~mode;
            system#set_mtime dst_path mtime
  )

let copy_tree_with_verify system source target manifest_data required_digest =
  let required_digest_str = format_digest required_digest in
  let alg, _ = required_digest in
  if alg = "sha1" then
    Safe_exn.failf "Sorry, the 'sha1' algorithm does not support copying.";

  let manifest_digest = (alg, hash_manifest alg manifest_data) in
  if manifest_digest <> required_digest then (
    Safe_exn.failf "Manifest has been tampered with!\n\
                Manifest digest: %s\n\
                Directory name : %s" (format_digest manifest_digest) required_digest_str
  );

  let target_impl = target +/ required_digest_str in
  if U.is_dir system target_impl then (
    log_info "Target directory '%s' already exists" target_impl
  ) else (
    (* We've checked that the source's manifest matches required_digest, so it
       is what we want. Make a list of all the files we need to copy... *)
    let req_tree = parse_manifest manifest_data in
    let tmp_dir = U.make_tmp_dir system ~mode:0o755 target in
    let hash_name =
      match alg with
      | "sha1" | "sha1new" -> "sha1"
      | "sha256" | "sha256new" -> "sha256"
      | _ -> Safe_exn.failf "Unknown manifest digest algorithm '%s'" alg in
    try
      copy_subtree system hash_name req_tree source tmp_dir;
      let mfile = tmp_dir +/ ".manifest" in
      mfile |> system#with_open_out [Open_creat;Open_excl;Open_wronly;Open_binary] ~mode:0o644 (fun oc ->
        output_string oc manifest_data
      );
      system#rename tmp_dir target_impl;
    with ex ->
      U.rmtree system ~even_if_locked:true tmp_dir;
      raise ex
  )
