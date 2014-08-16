(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open General

module U = Support.Utils
module Q = Support.Qdom
module FeedAttr = Constants.FeedAttr
module IfaceConfigAttr = Constants.IfaceConfigAttr

type t = Support.Qdom.element
type selection = Support.Qdom.element

type impl_source =
  | CacheSelection of Manifest.digest list
  | LocalSelection of string
  | PackageSelection

let re_initial_slash = Str.regexp "^/"
let re_package = Str.regexp "^package:"

let get_source elem =
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
        Q.raise_elem "No digests found for '%s':" id elem
      | digests -> digests
      )
  ) in source

let get_path system stores elem =
  match get_source elem with
  | PackageSelection -> None
  | LocalSelection path -> Some path
  | CacheSelection digests -> Some (Stores.lookup_any system digests stores)

let root_iface sels = ZI.get_attribute FeedAttr.interface sels
let root_command sels =
  match ZI.get_attribute_opt FeedAttr.command sels with
  | None | Some "" -> None
  | Some _ as command -> command

let iter fn sels = ZI.iter fn sels ~name:"selection"

(** Create a map from interface URI to <selection> elements. *)
let make_selection_map sels =
  let add_selection m sel =
    StringMap.add (ZI.get_attribute "interface" sel) sel m
  in ZI.fold_left ~f:add_selection StringMap.empty sels "selection"

let get_runner elem =
  match elem |> ZI.map ~name:"runner" (fun a -> a) with
  | [] -> None
  | [runner] -> Some runner
  | _ -> Q.raise_elem "Multiple <runner>s in" elem

let create root =
  ZI.check_tag "selections" root;
  let old_commands = root.Q.child_nodes |> List.filter (fun child -> ZI.tag child = Some "command") in
  if old_commands = [] then root
  else (
    (* 0launch 0.52 to 1.1 *)
    try
      let iface = ref (Some (root_iface root)) in
      let index = ref (make_selection_map root) in
      old_commands |> List.iter (fun command ->
        let current_iface = !iface |? lazy (Q.raise_elem "No additional command expected here!" command) in
        let sel = StringMap.find current_iface !index |? lazy (Q.raise_elem "Missing selection for '%s' needed by" current_iface command) in
        let command = {command with Q.attrs = command.Q.attrs |> Q.AttrMap.add_no_ns "name" "run"} in
        index := !index |> StringMap.add current_iface {sel with Q.child_nodes = command :: sel.Q.child_nodes};
        match get_runner command with
        | None -> iface := None
        | Some runner -> iface := Some (ZI.get_attribute "interface" runner)
      );
      {
        root with
        Q.child_nodes = !index |> StringMap.map_bindings (fun _ child -> child);
        Q.attrs = root.Q.attrs |> Q.AttrMap.add_no_ns "command" "run"
      }
    with Safe_exception _ as ex -> reraise_with_context ex "... migrating from old selections format"
  )

let load_selections system path =
  let root = Q.parse_file system path in
  create root

let get_feed elem =
  ZI.check_tag "selection" elem;
  match ZI.get_attribute_opt "from-feed" elem with
  | None -> ZI.get_attribute "interface" elem
  | Some feed -> feed

(** Get the direct dependencies (excluding any inside commands) of this <selection> or <command>. *)
let get_dependencies ~restricts elem =
  elem |> ZI.filter_map (fun node ->
    match ZI.tag node with
    | Some "requires" | Some "runner" -> Some node
    | Some "restricts" when restricts -> Some node
    | _ -> None
  )

let get_id sel =
  let feed_url = ZI.get_attribute_opt FeedAttr.from_feed sel |? lazy (ZI.get_attribute FeedAttr.interface sel) in
  Feed_url.({
  id = ZI.get_attribute FeedAttr.id sel;
  feed = Feed_url.parse feed_url;
})

let equal a b =
  Support.Qdom.compare_nodes ~ignore_whitespace:true a b = 0

let as_xml sels = sels

let find iface sels =
  let is_our_iface sel = ZI.tag sel = Some "selection" && ZI.get_attribute FeedAttr.interface sel = iface in
  try Some (List.find is_our_iface sels.Q.child_nodes)
  with Not_found -> None

let requires_compilation sels =
  let matches sel = ZI.tag sel = Some "selection" && (
    match ZI.get_attribute_opt IfaceConfigAttr.mode sel |> Option.map Impl_mode.parse with
      | Some `requires_compilation -> true
      | _ -> false
  ) in
  List.exists matches sels.Q.child_nodes

let root_sel sels =
  let iface = root_iface sels in
  find iface sels |? lazy (raise_safe "Can't find a selection for the root (%s)!" iface)
