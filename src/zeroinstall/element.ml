(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Type-safe access to the XML formats.
 * See:
 * http://0install.net/interface-spec.html
 * http://0install.net/selections-spec.html *)

open Support
open Support.Common
open General
open Constants

module Q = Support.Qdom
module AttrMap = Q.AttrMap

module Compile = Support.Qdom.NsQuery(COMPILE_NS)

type 'a t = Q.element

let xml_ns = "http://www.w3.org/XML/1998/namespace"

let simple_content elem =
  elem.Q.last_text_inside

type binding_node =
  [ `Environment | `Executable_in_path | `Executable_in_var | `Binding]

type binding =
  [ `Environment of [`Environment] t
  | `Executable_in_path of [`Executable_in_path] t
  | `Executable_in_var of [`Executable_in_var] t
  | `Binding of [`Binding] t ]

type dependency_node = [ `Requires | `Restricts | `Runner ]

type dependency =
  [ `Requires of [`Requires] t
  | `Restricts of [`Restricts] t
  | `Runner of [`Runner] t]

type attr_node =
  [ `Group
  | `Implementation
  | `Compile_impl
  | `Package_impl ]

(** Create a map from interface URI to <selection> elements. *)
let make_selection_map sels =
  sels |> ZI.fold_left ~init:XString.Map.empty ~name:"selection" (fun m sel ->
    XString.Map.add (ZI.get_attribute "interface" sel) sel m
  )

let get_runner elem =
  match elem |> ZI.map ~name:"runner" (fun a -> a) with
  | [] -> None
  | [runner] -> Some runner
  | _ -> Q.raise_elem "Multiple <runner>s in" elem

let parse_selections root =
  ZI.check_tag "selections" root;
  match root.Q.child_nodes |> List.filter (fun child -> ZI.tag child = Some "command") with
  | [] -> root
  | old_commands ->
      (* 0launch 0.52 to 1.1 *)
      try
        let iface = ref (Some (ZI.get_attribute FeedAttr.interface root)) in
        let index = ref (make_selection_map root) in
        old_commands |> List.iter (fun command ->
          let current_iface = !iface |? lazy (Q.raise_elem "No additional command expected here!" command) in
          let sel = XString.Map.find_opt current_iface !index |? lazy (Q.raise_elem "Missing selection for '%s' needed by" current_iface command) in
          let command = {command with Q.attrs = command.Q.attrs |> AttrMap.add_no_ns "name" "run"} in
          index := !index |> XString.Map.add current_iface {sel with Q.child_nodes = command :: sel.Q.child_nodes};
          match get_runner command with
          | None -> iface := None
          | Some runner -> iface := Some (ZI.get_attribute "interface" runner)
        );
        {
          root with
          Q.child_nodes = !index |> XString.Map.map_bindings (fun _ child -> child);
          Q.attrs = root.Q.attrs |> AttrMap.add_no_ns "command" "run"
        }
      with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... migrating from old selections format"

let selections = ZI.map (fun x -> x) ~name:"selection"

let rec filter_if_0install_version node =
  match node.Q.attrs |> AttrMap.get_no_ns FeedAttr.if_0install_version with
  | Some expr when not (Version.parse_expr expr About.parsed_version) -> None
  | Some _expr -> Some {
    node with Q.child_nodes = List.filter_map filter_if_0install_version node.Q.child_nodes;
    attrs = node.Q.attrs |> AttrMap.remove ("", FeedAttr.if_0install_version) 
  }
  | None -> Some {
    node with Q.child_nodes = List.filter_map filter_if_0install_version node.Q.child_nodes;
  }

let parse_feed root =
  let root =
    match filter_if_0install_version root with
    | Some root -> root
    | None -> Q.raise_elem "Feed requires 0install version %s (we are %s):" (ZI.get_attribute FeedAttr.if_0install_version root) About.version root
  in

  begin match ZI.tag root with
  | Some "interface" | Some "feed" -> ()
  | _ ->
      ZI.check_ns root;
      Q.raise_elem "Expected <interface>, not" root end;

  ZI.get_attribute_opt "min-injector-version" root
  |> if_some (fun min_version ->
      if Version.parse min_version > About.parsed_version then
        Q.raise_elem "Feed requires 0install version %s or later (we are %s):" min_version About.version root
  );
  root

let make_impl ?source_hint ?child_nodes attrs =
  ZI.make ?source_hint ?child_nodes ~attrs "implementation"

let make_command ?path ?shell_command ~source_hint name =
  let attrs = AttrMap.singleton "name" name in
  let attrs = match path with
    | None -> attrs
    | Some path -> attrs |> AttrMap.add_no_ns "path" path in
  let attrs = match shell_command with
    | None -> attrs
    | Some shell_command -> attrs |> AttrMap.add_no_ns "shell-command" shell_command in
  ZI.make ~attrs ?source_hint "command"

let with_interface iface elem =
  {elem with Q.attrs = elem.Q.attrs |> Q.AttrMap.add_no_ns "interface" iface}

let get_command name elem =
  let is_command node = ((ZI.tag node = Some "command") && (ZI.get_attribute "name" node = name)) in
  Q.find is_command elem

let get_command_ex name elem =
  match get_command name elem with
  | Some command -> command
  | None -> Q.raise_elem "No <command> with name '%s' in" name elem

let path = ZI.get_attribute_opt "path"
let local_path = ZI.get_attribute_opt "local-path"
let command_name = ZI.get_attribute "name"
let binding_name = command_name

let arg_children parent =
  parent |> ZI.filter_map (fun child ->
    match ZI.tag child with
    | Some "arg" -> Some (`Arg child)
    | Some "for-each" -> Some (`For_each child)
    | _ -> None
  )

let bool_opt attr elem =
  match Q.AttrMap.get attr elem.Q.attrs with
  | Some "true" -> Some true
  | Some "false" -> Some false
  | Some x -> Q.raise_elem "Invalid '%s' value '%s' on" (snd attr) x elem
  | None -> None

let item_from = ZI.get_attribute "item-from"
let separator = ZI.get_attribute_opt "separator"
let command = ZI.get_attribute_opt "command"
let interface = ZI.get_attribute "interface"
let from_feed = ZI.get_attribute_opt "from-feed"
let version = ZI.get_attribute "version"
let version_opt = ZI.get_attribute_opt "version"
let id = ZI.get_attribute "id"
let doc_dir = ZI.get_attribute_opt "doc-dir"
let arch elem = Q.AttrMap.get_no_ns "arch" elem.Q.attrs
let source = bool_opt ("", "source")

let uri = ZI.get_attribute_opt "uri"
let uri_exn = ZI.get_attribute "uri"
let src = ZI.get_attribute "src"
let langs = ZI.get_attribute_opt "langs"
let main = ZI.get_attribute_opt "main"
let self_test = ZI.get_attribute_opt "self-test"
let before = ZI.get_attribute_opt "before"
let not_before = ZI.get_attribute_opt "not-before"
let os elem = ZI.get_attribute_opt "os" elem |> pipe_some Arch.parse_os
let use = ZI.get_attribute_opt "use"
let distribution = ZI.get_attribute_opt "distribution"
let distributions = ZI.get_attribute_opt "distributions"
let href = ZI.get_attribute "href"
let icon_type = ZI.get_attribute_opt "type"

let insert = ZI.get_attribute_opt "insert"
let value = ZI.get_attribute_opt "value"
let mode = ZI.get_attribute_opt "mode"
let default = ZI.get_attribute_opt "default"

let feed_metadata root =
  root.Q.child_nodes |> List.filter_map (fun node ->
    match ZI.tag node with
    | Some "name" -> Some (`Name node)
    | Some "feed" -> Some (`Feed_import node)
    | Some "feed-for" -> Some (`Feed_for node)
    | Some "category" -> Some (`Category node)
    | Some "needs-terminal" -> Some (`Needs_terminal node)
    | Some "homepage" -> Some (`Homepage node)
    | Some "icon" -> Some (`Icon node)
    | Some "replaced-by" -> Some (`Replaced_by node)
    | _ -> None
  )

let group_children group =
  group.Q.child_nodes |> List.filter_map (fun node ->
    match ZI.tag node with
    | Some "group" -> Some (`Group node)
    | Some "implementation" -> Some (`Implementation node)
    | Some "package-implementation" -> Some (`Package_impl node)
    | _ -> None
  )

let package = ZI.get_attribute "package"
let quick_test_file = ZI.get_attribute_opt FeedAttr.quick_test_file
let quick_test_mtime elem = ZI.get_attribute_opt FeedAttr.quick_test_mtime elem |> pipe_some (fun s -> Some (Int64.of_string s))

let compile_command group = group.Q.attrs |> AttrMap.get (COMPILE_NS.ns, "command")
let compile_min_version sel = sel.Q.attrs |> AttrMap.get (COMPILE_NS.ns, "min-version")
let requires_compilation = bool_opt ("", "requires-compilation")

let is_retrieval_method elem =
  match ZI.tag elem with
  | Some "archive" | Some "file" | Some "recipe" -> true
  | _ -> false

let retrieval_methods impl =
  List.filter is_retrieval_method impl.Q.child_nodes

let classify_retrieval elem =
  match ZI.tag elem with
  | Some "archive" -> `Archive elem
  | Some "file" -> `File elem
  | Some "recipe" -> `Recipe elem
  | _ -> assert false

let size elem =
  let s = ZI.get_attribute "size" elem in
  try Int64.of_string s
  with _ -> Safe_exn.failf "Invalid size '%s'" s

let dest = ZI.get_attribute "dest"
let executable = bool_opt ("", "executable")
let rename_source = ZI.get_attribute "source"
let dest_opt = ZI.get_attribute_opt "dest"
let extract = ZI.get_attribute_opt "extract"
let mime_type = ZI.get_attribute_opt "type"
let remove_path = ZI.get_attribute "path"

let start_offset elem =
  match ZI.get_attribute_opt "start-offset" elem with
  | None -> None
  | Some s ->
    try Some (Int64.of_string s)
    with _ -> Safe_exn.failf "Invalid offset '%s'" s

exception Unknown_step

let recipe_steps elem =
  let parse_step child =
    match ZI.tag child with
    | Some "archive" -> Some (`Archive child)
    | Some "file" -> Some (`File child)
    | Some "rename" -> Some (`Rename child)
    | Some "remove" -> Some (`Remove child)
    | Some _ -> raise Unknown_step
    | None -> None in
  try Some (List.filter_map parse_step elem.Q.child_nodes)
  with Unknown_step -> None

let importance dep =
  match ZI.get_attribute_opt FeedAttr.importance dep with
  | None | Some "essential" -> `Essential
  | _ -> `Recommended

let classify_dep elem =
  match ZI.tag elem with
  | Some "runner" -> `Runner elem
  | Some "requires" -> `Requires elem
  | Some "restricts" -> `Restricts elem
  | _ -> assert false

let classify_binding_opt child =
  match ZI.tag child with
  | Some "environment" -> Some (`Environment child)
  | Some "executable-in-path" -> Some (`Executable_in_path child)
  | Some "executable-in-var" -> Some (`Executable_in_var child)
  | Some "binding" | Some "overlay" -> Some (`Binding child)
  | _ -> None

let classify_binding elem =
  match classify_binding_opt elem with
  | Some b -> b
  | None -> assert false

let bindings parent =
  ZI.filter_map classify_binding_opt parent

let element_of_dependency = function
  | `Requires d -> d
  | `Runner d -> d
  | `Restricts d -> d

let element_of_binding = function
  | `Environment b -> b
  | `Executable_in_path b -> b
  | `Executable_in_var b -> b
  | `Binding b -> b

let restrictions parent =
  parent |> ZI.filter_map (fun child ->
    match ZI.tag child with
    | Some "version" -> Some (`Version child)
    | _ -> None
  )

let raise_elem = Q.raise_elem
let log_elem = Q.log_elem
let as_xml x = x
let pp = Q.pp_with_loc

let deps_and_bindings sel =
  sel |> ZI.filter_map (fun child ->
    match ZI.tag child with
    | Some "requires" -> Some (`Requires child)
    | Some "restricts" -> Some (`Restricts child)
    | Some "command" -> Some (`Command child)
    | _ -> classify_binding_opt child
  )

let command_children sel =
  sel |> ZI.filter_map (fun child ->
    match ZI.tag child with
    | Some "requires" -> Some (`Requires child)
    | Some "restricts" -> Some (`Restricts child)
    | Some "runner" -> Some (`Runner child)
    | _ -> classify_binding_opt child
  )

let compile_template =
  Q.find (fun child ->
    Compile.tag child = Some "implementation"
  )

let compile_include_binary = bool_opt (COMPILE_NS.ns, "include-binary")

let get_text tag langs feed =
  let best = ref None in
  feed |> ZI.iter ~name:tag (fun elem ->
    let new_score = elem.Q.attrs |> AttrMap.get (xml_ns, FeedAttr.lang) |> Support.Locale.score_lang langs in
    match !best with
    | Some (_old_summary, old_score) when new_score <= old_score -> ()
    | _ -> best := Some (elem.Q.last_text_inside, new_score)
  );
  match !best with
  | None -> None
  | Some (summary, _score) -> Some summary

let get_summary = get_text "summary"
let get_description = get_text "description"

let dummy_restricts = ZI.make "restricts"
