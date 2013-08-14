(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Handling <recipe>, <archive> and similar elements *)

open General
open Support.Common
module Qdom = Support.Qdom
module U = Support.Utils

type archive_options = {
  extract : string option;
  start_offset : int option;
  mime_type : string option;
}

type download_type =
  | FileDownload
  | ArchiveDownload of archive_options

type download = {
  url : string;
  size : int;
  dest : string option;
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

let attr_href = "href"
let attr_size = "size"
let attr_extract = "extract"
let attr_start_offset = "start-offset"
let attr_type = "type"
let attr_dest = "dest"
let attr_source = "source"
let attr_path = "path"

let parse_archive elem = DownloadStep {
    url = ZI.get_attribute attr_href elem;
    size = int_of_string @@ ZI.get_attribute attr_size elem;
    dest = ZI.get_attribute_opt attr_dest elem;
    download_type = ArchiveDownload {
      extract = ZI.get_attribute_opt attr_extract elem;
      start_offset = (
        match ZI.get_attribute_opt attr_start_offset elem with
        | None -> None
        | Some s -> Some (int_of_string s)
      );
      mime_type = ZI.get_attribute_opt attr_type elem;
    };
  }

let parse_file_elem elem = DownloadStep {
  url = ZI.get_attribute attr_href elem;
  size = int_of_string @@ ZI.get_attribute attr_size elem;
  dest = ZI.get_attribute_opt attr_dest elem;
  download_type = FileDownload;
}

let parse_rename elem = RenameStep {
  rename_source = ZI.get_attribute attr_source elem;
  rename_dest = ZI.get_attribute attr_dest elem;
}

let parse_remove elem = RemoveStep {
  remove = ZI.get_attribute attr_path elem
}

exception Unknown_step

let parse_recipe elem =
  let parse_step child =
    match ZI.tag child with
    | Some "archive" -> Some (parse_archive child)
    | Some "file" -> Some (parse_file_elem child)
    | Some "rename" -> Some (parse_rename child)
    | Some "remove" -> Some (parse_remove child)
    | Some _ -> raise Unknown_step
    | None -> None in
  U.filter_map ~f:parse_step elem.Qdom.child_nodes

let is_retrieval_method elem =
  match ZI.tag elem with
  | Some "archive" | Some "file" | Some "recipe" -> true
  | _ -> false

let parse_retrieval_method elem =
  match ZI.tag elem with
  | Some "archive" -> Some [ parse_archive elem ]
  | Some "file" -> Some [ parse_file_elem elem ]
  | Some "recipe" -> (
      try Some (parse_recipe elem)
      with Unknown_step -> None
  )
  | _ -> None

let re_scheme_sep = Str.regexp ".*://"

let recipe_requires_network recipe =
  let requires_network = function
    | DownloadStep {url;_} -> Str.string_match re_scheme_sep url 0
    | RenameStep _ -> false
    | RemoveStep _ -> false in
  List.exists requires_network recipe
