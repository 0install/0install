(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common

module U = Support.Utils
module Q = Support.Qdom

type selection = [`selection] Element.t

type t = {
  root : [`selections] Element.t;
  index : selection StringMap.t;
}

type impl_source =
  | CacheSelection of Manifest.digest list
  | LocalSelection of string
  | PackageSelection

let re_initial_slash = Str.regexp "^/"
let re_package = Str.regexp "^package:"

let get_source elem =
  match Element.local_path elem with
  | Some path -> LocalSelection path
  | None -> let id = Element.id elem in
    if Str.string_match re_initial_slash id 0 then
      LocalSelection id   (* Backwards compatibility *)
    else if Str.string_match re_package id 0 then
      PackageSelection
    else
      CacheSelection (match Stores.get_digests elem with
      | [] ->
          let id = Element.id elem in
          Element.raise_elem "No digests found for '%s':" id elem
      | digests -> digests
      )

let get_path system stores elem =
  match get_source elem with
  | PackageSelection -> None
  | LocalSelection path -> Some path
  | CacheSelection digests -> Some (Stores.lookup_any system digests stores)

let root_iface sels = Element.interface sels.root

let root_command sels =
  match Element.command sels.root with
  | None | Some "" -> None
  | Some _ as command -> command

let iter fn sels = StringMap.iter fn sels.index

(** Create a map from interface URI to <selection> elements. *)
let make_selection_map sels =
  Element.selections sels |> List.fold_left (fun m sel ->
    StringMap.add (Element.interface sel) sel m
  ) StringMap.empty

let create root =
  let root = Element.parse_selections root in
  { root; index = make_selection_map root }

let load_selections system path =
  let root = Q.parse_file system path in
  create root

let get_feed elem =
  match Element.from_feed elem with
  | None -> Element.interface elem
  | Some feed -> feed

let get_id sel =
  let feed_url = Element.from_feed sel |? lazy (Element.interface sel) in
  Feed_url.({
    id = Element.id sel;
    feed = Feed_url.parse feed_url;
  })

let equal a b =
  Support.Qdom.compare_nodes ~ignore_whitespace:true (Element.as_xml a.root) (Element.as_xml b.root) = 0

let as_xml sels = Element.as_xml sels.root

let find iface sels = StringMap.find iface sels.index

let find_ex iface sels = find iface sels |? lazy (raise_safe "Interface '%s' not found in selections!" iface)

let root_sel sels =
  let iface = root_iface sels in
  find iface sels |? lazy (raise_safe "Can't find a selection for the root (%s)!" iface)

(* Return all bindings in document order *)
let collect_bindings t =
  let bindings = ref [] in

  let process_dep dep =
    let dep_iface = Element.interface dep in
    if StringMap.mem dep_iface t.index then (
      let add_iface b = (dep_iface, b) in
      bindings := List.map add_iface (Element.bindings dep) @ !bindings
    ) in
  let process_command iface command =
    Element.command_children command |> List.iter (function
      | `requires r -> process_dep r
      | `runner r -> process_dep r
      | `restricts r -> process_dep r
      | #Element.binding as binding -> bindings := (iface, binding) :: !bindings
    ) in
  let process_impl iface parent =
    Element.deps_and_bindings parent |> List.iter (function
      | `requires r -> process_dep r
      | `restricts r -> process_dep r
      | `command c -> process_command iface c
      | #Element.binding as binding -> bindings := (iface, binding) :: !bindings
    ) in

  t |> iter (fun iface node ->
    try process_impl iface node
    with Safe_exception _ as ex -> reraise_with_context ex "... getting bindings from selection %s" iface
  );
  List.rev !bindings
