(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common

module H = Support.Hash
module U = Support.Utils

type digest = string * string

let format_digest (alg, value) =
  let s = match alg with
  | "sha1" | "sha1new" | "sha256" -> alg ^ "=" ^ value
  | _ -> alg ^ "_" ^ value in
  (* validate *)
  s

let parse_digest digest =
  [ "sha1="; "sha1new="; "sha256="; "sha256new_"] |> U.first_match ~f:(fun prefix ->
    if U.starts_with digest prefix then (
      let alg = String.sub prefix 0 (String.length prefix - 1) in
      let value = U.string_tail digest (String.length prefix) in
      Some (alg, value)
    ) else None
  ) |? lazy (raise_safe "Unknown digest type '%s'" digest)

let generate_manifest (system:system) alg root =
  let old = (alg = "sha1") in
  let hash_name =
    match alg with
    | "sha1" | "sha1new" -> "sha1"
    | "sha256" | "sha256new" -> "sha256"
    | _ -> raise_safe "Unknown manifest digest algorithm '%s'" alg in

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

(** Generate the final overall hash of the manifest. *)
let hash_manifest alg manifest_contents =
  let hash_name =
    match alg with
    | "sha1" | "sha1new" -> "sha1"
    | "sha256" | "sha256new" -> "sha256"
    | _ -> raise_safe "Unknown manifest digest algorithm '%s'" alg in
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
      raise_safe "Directory '%s' already contains a .manifest file!" dir;

    let manifest_contents = generate_manifest system alg dir in

    system#chmod dir 0o755;
    system#atomic_write [Open_wronly; Open_binary] mfile ~mode:0o444 (fun ch ->
      output_string ch manifest_contents
    );
    system#chmod dir 0o555;
    hash_manifest alg manifest_contents
  with Safe_exception _ as ex -> reraise_with_context ex "... adding .manifest file in %s" dir

let algorithm_names = [
  "sha1";
  "sha1new";
  "sha256";
  "sha256new";
]

(* This is really only useful for [diff].
 * We return a list of tuples (path, line), making it easy for the diff code to compare the
 * order of entries from different manifests. *)
let parse_manifest ~old manifest_data =
  let dir = ref "/" in
  let items = ref [] in
  let i = ref 0 in
  try
    while true do
      let nl =
        try String.index_from manifest_data !i '\n' 
        with Not_found -> raise End_of_file in
      let line = String.sub manifest_data !i (nl - !i) in
      i := nl + 1;
      let n_parts =
        match line.[0] with
        | 'D' when old -> 3
        | 'D' -> 2
        | 'S' -> 4
        | 'X' | 'F' -> 5
        | _ -> raise_safe "Malformed manifest line: '%s'" line in
      let parts = Str.bounded_split_delim U.re_space line n_parts in
      if List.length parts < n_parts then raise_safe "Malformed manifest line: '%s'" line;
      let name = List.nth parts (n_parts - 1) in
      if line.[0] = 'D' then (
        dir := name;
        items := (name, line) :: !items
      ) else (
        items := (!dir ^ "/" ^ name, line) :: !items
      )
    done;
    assert false
  with End_of_file -> List.sort compare !items

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
    (parse_manifest ~old adata)
    (parse_manifest ~old bdata)

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

    raise (Safe_exception (trim @@ Buffer.contents b, ref []))
  )
