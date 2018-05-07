(* Copyright (C) 2018, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Handling <recipe>, <archive> and similar elements *)

open Support.Common

type archive_options = {
  dest : string option;
  extract : string option;
  start_offset : Int64.t;
  mime_type : string option;
}

module FileDownload = struct
  type t = {
    dest : string;
    executable : bool;
  }

  let parse elem =
    {
      dest = Element.dest elem;
      executable = Element.executable elem |> default false;
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

let parse_archive elem = DownloadStep {
    url = Element.href elem;
    size = Some (Element.size elem);
    download_type = ArchiveDownload {
      dest = Element.dest_opt elem;
      extract = Element.extract elem;
      start_offset = Element.start_offset elem |> default Int64.zero;
      mime_type = Element.mime_type elem;
    };
  }

let parse_file_elem elem = DownloadStep {
  url = Element.href elem;
  size = Some (Element.size elem);
  download_type = FileDownload (FileDownload.parse elem);
}

let parse_rename elem = RenameStep {
  rename_source = Element.rename_source elem;
  rename_dest = Element.dest elem;
}

let parse_remove elem = RemoveStep {
  remove = Element.remove_path elem;
}

let parse_step = function
  | `Archive child -> parse_archive child
  | `File child    -> parse_file_elem child
  | `Rename child  -> parse_rename child
  | `Remove child  -> parse_remove child

let parse_retrieval_method elem =
  match Element.classify_retrieval elem with
  | `Archive elem -> Some [ parse_archive elem ]
  | `File elem -> Some [ parse_file_elem elem ]
  | `Recipe elem ->
      match Element.recipe_steps elem with
      | None -> None
      | Some steps -> Some (List.map parse_step steps)

let re_scheme_sep = Str.regexp ".*://"

let recipe_requires_network recipe =
  let requires_network = function
    | DownloadStep {url;_} -> Str.string_match re_scheme_sep url 0
    | RenameStep _ -> false
    | RemoveStep _ -> false in
  List.exists requires_network recipe

let get_step_size = function
  | DownloadStep {size = Some size; _} -> size
  | DownloadStep {size = None; _} -> Int64.zero
  | RenameStep _ -> Int64.zero
  | RemoveStep _ -> Int64.zero

let get_download_size steps =
  List.fold_left (fun a step -> Int64.add a @@ get_step_size step) Int64.zero steps

let get_mirror_download mirror_archive_url = [
  DownloadStep {
    url = mirror_archive_url;
    size = None;
    download_type = ArchiveDownload {
      dest = None;
      extract = None;
      start_offset = Int64.zero;
      mime_type = Some "application/x-bzip-compressed-tar";
    }
  }
]
