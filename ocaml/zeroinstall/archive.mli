(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Unpacking archives *)

type mime_type = string

(* Guess the MIME type from the URL's extension.
 * @raise Safe_exn.T if the extension is unknown. *)
val type_from_url : string -> mime_type

(* Check we have the needed software to extract from an archive of the given type.
 * @raise Safe_exn.T with a suitable message if not. *)
val check_type_ok : Support.Common.system -> mime_type -> unit

(** Unpack [archive] to a temporary directory and then move things into [destdir], checking that we're not following symlinks at each
    stage. Use this when you want to unpack an archive into a directory which already has stuff in it.
    @param extract treat this subdirectory of [archive] as the root to unpack.
    @param tmpdir a directory on the same filesystem as [destdir] in which to create temporary directories.
  *)
val unpack_over : ?extract:Support.Common.filepath -> General.config ->
                  archive:Support.Common.filepath -> tmpdir:Support.Common.filepath -> destdir:Support.Common.filepath ->
                  mime_type:mime_type -> unit Lwt.t
