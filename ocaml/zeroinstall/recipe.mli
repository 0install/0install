(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Handling <recipe>, <archive> and similar elements *)

type archive_options = {
  dest : string option;
  extract : string option;
  start_offset : Int64.t;
  mime_type : string option;
}

module FileDownload : sig
  type t = {
    dest : string;
    executable : bool;
  }
end

type download_type =
  | FileDownload of FileDownload.t
  | ArchiveDownload of archive_options

type download = {
  url : string;
  size : Int64.t option;          (* may be None when using the mirror *)
  download_type : download_type;
}

type rename = {
  rename_source : string;
  rename_dest : string;
}

type remove = {
  remove : string;
}

type recipe_step =
  | DownloadStep of download
  | RenameStep of rename
  | RemoveStep of remove

type t = recipe_step list

val parse_retrieval_method : [`Archive | `File | `Recipe] Element.t -> t option

val recipe_requires_network : t -> bool
val get_download_size : t -> Int64.t

val get_mirror_download : string -> t
