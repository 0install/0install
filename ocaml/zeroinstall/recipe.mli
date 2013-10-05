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

type download_type =
  | FileDownload of string    (* dest *)
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

type recipe = recipe_step list

val is_retrieval_method : Support.Qdom.element -> bool
val parse_retrieval_method : Support.Qdom.element -> recipe option

val recipe_requires_network : recipe -> bool
val get_download_size : recipe -> Int64.t

val get_mirror_download : string -> recipe
