(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Managing cached implementations *)

open General
open Support.Common
module U = Support.Utils

type stores = string list

type digest = (string * string)

type available_digests = (string, bool) Hashtbl.t

exception Not_stored of string;;

let first_match = Support.Utils.first_match

let format_digest (alg, value) =
  let s = match alg with
  | "sha1" | "sha1new" | "sha256" -> alg ^ "=" ^ value
  | _ -> alg ^ "_" ^ value in
  (* validate *)
  s;;

let lookup_digest (system:system) stores digest =
  let check_store store = (
    let path = Filename.concat store (format_digest digest) in
    if system#file_exists path then Some path else None
  ) in first_match check_store stores

let lookup_maybe system digests stores = first_match (lookup_digest system stores) digests

let lookup_any system digests stores =
  match lookup_maybe system digests stores with
  | Some path -> path
  | None ->
      let str_digests = String.concat ", " (List.map format_digest digests) in
      let str_stores = String.concat ", " stores in
      raise (Not_stored ("Item with digests " ^ str_digests ^ " not found in stores. Searched " ^ str_stores));;

let get_default_stores basedir_config =
  let open Support.Basedir in
  List.map (fun prefix -> prefix +/ "0install.net" +/ "implementations") basedir_config.cache

let get_available_digests (system:system) stores =
  let digests = Hashtbl.create 1000 in
  let scan_dir dir =
    match system#readdir dir with
    | Success items ->
        for i = 0 to Array.length items - 1 do
          Hashtbl.add digests items.(i) true
        done
    | Problem _ -> log_debug "Can't scan %s" dir
    in
  List.iter scan_dir stores;
  digests

let check_available available_digests digests =
  List.exists (fun d -> Hashtbl.mem available_digests (format_digest d)) digests

let get_digests elem =
  let id = ZI.get_attribute "id" elem in
  let init = match Str.bounded_split_delim U.re_equals id 2 with
  | [key; value] when key = "sha1" || key = "sha1new" || key = "sha256" -> [(key, value)]
  | _ -> [] in

  let check_attr init ((ns, name), value) = match ns with
    | "" -> (name, value) :: init
    | _ -> init in
  let extract_digests init elem =
    List.fold_left check_attr init elem.Support.Qdom.attrs in
  ZI.fold_left ~f:extract_digests init elem "manifest-digest";;
