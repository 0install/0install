(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** <selection> elements *)

open Support.Common
open General

module Qdom = Support.Qdom

type impl_source =
  | CacheSelection of Stores.digest list
  | LocalSelection of string
  | PackageSelection
;;

let re_initial_slash = Str.regexp "^/";;
let re_package = Str.regexp "^package:";;

let get_digests elem =
  (* todo: ID *)
  let check_attr init ((ns, name), value) = match ns with
    | "" -> (name, value) :: init
    | _ -> init in
  let extract_digests init elem =
    List.fold_left check_attr init elem.Qdom.attrs in
  ZI.fold_left extract_digests [] elem "manifest-digest";;

let make_selection elem =
  let source = (match ZI.get_attribute_opt "local-path" elem with
  | Some path -> LocalSelection path
  | None -> let id = ZI.get_attribute "id" elem in
    if Str.string_match re_initial_slash id 0 then
      LocalSelection id   (* Backwards compatibility *)
    else if Str.string_match re_package id 0 then
      PackageSelection
    else
      CacheSelection (match get_digests elem with
      | [] ->
        let id = ZI.get_attribute "id" elem in
        Qdom.raise_elem ("No digests found in selection '" ^ id ^ "': ") elem
      | digests -> digests
      )
  ) in source
;;

let find_ex iface impls =
  try StringMap.find iface impls
  with Not_found -> raise_safe "Missing a selection for interface '%s'" iface
;;

let get_path stores elem =
  match make_selection elem with
  | PackageSelection -> None
  | LocalSelection path -> Some path
  | CacheSelection digests -> Some (Stores.lookup_any digests stores)
;;

let load_selections system path =
  let root = Qdom.parse_file system path in
  ZI.check_tag "selections" root;
  root
;;

let get_feed elem =
  ZI.check_tag "selection" elem;
  match ZI.get_attribute_opt "from-feed" elem with
  | None -> ZI.get_attribute "interface" elem
  | Some feed -> feed
;;

let get_unavailable_selections config ~include_packages sels =
  let missing = ref [] in

  let needs_download elem =
    match make_selection elem with
    | LocalSelection _ -> false
    | CacheSelection digests -> None = Stores.lookup_maybe digests config.stores
    | PackageSelection when not include_packages -> false
    | PackageSelection -> not @@ Distro.is_installed config elem
  in
  let check sel =
    if needs_download sel then missing := sel :: !missing
  in

  ZI.iter_with_name check sels "selection";

  !missing
;;
