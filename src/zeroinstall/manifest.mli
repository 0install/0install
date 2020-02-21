(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Generating the .manifest files *)

type alg = string
type digest = string * string

val parse_digest : string -> digest

(* Less strict version of parse_digest that also accepts the alg=* form for all digests.
 * Use this to process input from the user (but use [parse_digest] to get the digest
 * from a directory name). *)
val parse_digest_loose : string -> digest

val format_digest : digest -> string

val algorithm_names : string list

(** [generate_manifest system alg dir] scans [dir] and return the contents of the generated manifest.
 * If the directory contains a .manifest file at the top level, it is ignored. *)
val generate_manifest : #Support.Common.filesystem -> alg -> Support.Common.filepath -> string

(** Generate the final overall hash value of the manifest. *)
val hash_manifest : alg -> string -> string

(** Writes a .manifest file into 'dir', and returns the digest.
    You should call Stores.fixup_permissions before this to ensure that the permissions are correct.
    On exit, dir itself has mode 555. Subdirectories are not changed.
    @return the value part of the digest of the manifest. *)
val add_manifest_file : #Support.Common.filesystem -> alg -> Support.Common.filepath -> string

(** Ensure that directory 'dir' generates the given digest.
    @param digest the required digest (usually this is just [Filename.basename dir])
    For a non-error return:
    - The calculated digest of the contents must match [digest].
    - If there is a .manifest file, then its digest must also match. *)
val verify : #Support.Common.filesystem -> digest:digest -> Support.Common.filepath -> unit

(** Copy directory source to be a subdirectory of target if it matches the required_digest.
    manifest_data is normally source/.manifest. source and manifest_data are not trusted
    (will typically be under the control of another user).
    The copy is first done to a temporary directory in target, then renamed to the final name
    only if correct. Therefore, an invalid 'target/required_digest' will never exist.
    A successful return means than target/required_digest now exists (whether we created it or not). *)
val copy_tree_with_verify : #Support.Common.filesystem ->
  Support.Common.filepath -> Support.Common.filepath -> string -> digest -> unit

type hash = string
type mtime = float
type size = Int64.t

type manifest_dir = (Support.Common.filepath * tree_node) list
and tree_node =
  [ `Dir of manifest_dir
  | `Symlink of (hash * size)
  | `File of (bool * hash * mtime * size) ]

(* Parse a manifest into a tree structure.
   Note: must be a new-style manifest (not "sha1") *)
val parse_manifest : string -> manifest_dir
