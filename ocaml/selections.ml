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

let make_selection elem =
  let source = (match ZI.get_attribute_opt "local-path" elem with
  | Some path -> LocalSelection path
  | None -> let id = ZI.get_attribute "id" elem in
    if Str.string_match re_initial_slash id 0 then
      LocalSelection id   (* Backwards compatibility *)
    else if Str.string_match re_package id 0 then
      PackageSelection
    else
      CacheSelection (match Stores.get_digests elem with
      | [] ->
        let id = ZI.get_attribute "id" elem in
        Qdom.raise_elem "No digests found for '%s':" id elem
      | digests -> digests
      )
  ) in source
;;

let find_ex iface impls =
  try StringMap.find iface impls
  with Not_found -> raise_safe "Missing a selection for interface '%s'" iface
;;

let get_path system stores elem =
  match make_selection elem with
  | PackageSelection -> None
  | LocalSelection path -> Some path
  | CacheSelection digests -> Some (Stores.lookup_any system digests stores)
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

(** If [distro] is set then <package-implementation>s are included. Otherwise, they are ignored. *)
let get_unavailable_selections config ?distro sels =
  let missing = ref [] in

  let needs_download elem =
    match make_selection elem with
    | LocalSelection _ -> false
    | CacheSelection digests -> None = Stores.lookup_maybe config.system digests config.stores
    | PackageSelection ->
        match distro with
        | None -> false
        | Some distro -> not @@ Distro.is_installed config distro elem
  in
  let check sel =
    if needs_download sel then (
      Qdom.log_elem Support.Logging.Info "Missing selection of %s:" (ZI.get_attribute "interface" sel) sel;
      missing := sel :: !missing
    )
  in

  ZI.iter_with_name ~f:check sels "selection";

  !missing

(** Get the direct dependencies (excluding any inside commands) of this <selection> or <command>. *)
let get_dependencies ~restricts elem =
  ZI.filter_map elem ~f:(fun node ->
    match ZI.tag node with
    | Some "requires" | Some "runner" -> Some node
    | Some "restricts" when restricts -> Some node
    | _ -> None
  )

(** Collect all the commands needed by this dependency. *)
let get_required_commands dep =
  let commands =
    ZI.filter_map dep ~f:(fun node ->
      match Binding.parse_binding node with
      | Some binding -> Binding.get_command binding
      | None -> None
    ) in
  match ZI.tag dep with
  | Some "runner" -> (default "run" @@ ZI.get_attribute_opt "command" dep) :: commands
  | Some "requires" | Some "restricts" -> commands
  | _ -> Qdom.raise_elem "Not a dependency: " dep
