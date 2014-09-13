(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Type-safe access to the XML formats.
 * See:
 * http://0install.net/interface-spec.html
 * http://0install.net/selections-spec.html *)

open Support.Common
open General
open Constants

module Q = Support.Qdom

type 'a t = Q.element

type binding =
  [ `environment of [`environment] t
  | `executable_in_path of [`executable_in_path] t
  | `executable_in_var of [`executable_in_var] t
  | `binding of [`binding] t ]

type dependency =
  [ `requires of [`requires] t
  | `restricts of [`restricts] t
  | `runner of [`runner] t]

(** Create a map from interface URI to <selection> elements. *)
let make_selection_map sels =
  sels |> ZI.fold_left ~init:StringMap.empty ~name:"selection" (fun m sel ->
    StringMap.add (ZI.get_attribute "interface" sel) sel m
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

let selections = ZI.map (fun x -> x) ~name:"selection"

let make_command ~source_hint = ZI.make ?source_hint "command"

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
    | Some "arg" -> Some (`arg child)
    | Some "for-each" -> Some (`for_each child)
    | _ -> None
  )

let item_from = ZI.get_attribute "item-from"
let separator = ZI.get_attribute_opt "separator"
let command = ZI.get_attribute_opt "command"
let interface = ZI.get_attribute "interface"
let from_feed = ZI.get_attribute_opt "from-feed"
let version = ZI.get_attribute "version"
let version_opt = ZI.get_attribute_opt "version"
let id = ZI.get_attribute "id"
let doc_dir = ZI.get_attribute_opt "doc-dir"
let arch = ZI.get_attribute_opt "arch"

let package = ZI.get_attribute "package"
let quick_test_file = ZI.get_attribute_opt FeedAttr.quick_test_file
let quick_test_mtime elem = ZI.get_attribute_opt FeedAttr.quick_test_mtime elem |> pipe_some (fun s -> Some (Int64.of_string s))

let compile_min_version sel =
  sel.Q.attrs |> Q.AttrMap.get (COMPILE_NS.ns, "min-version")

let importance dep =
  match ZI.get_attribute_opt FeedAttr.importance dep with
  | None | Some "essential" -> `essential
  | _ -> `recommended

let classify_dep elem =
  match ZI.tag elem with
  | Some "runner" -> `runner elem
  | Some "requires" -> `requires elem
  | Some "restricts" -> `restricts elem
  | _ -> assert false

let classify_binding_opt child =
  match ZI.tag child with
  | Some "environment" -> Some (`environment child)
  | Some "executable-in-path" -> Some (`executable_in_path child)
  | Some "executable-in-var" -> Some (`executable_in_var child)
  | Some "binding" | Some "overlay" -> Some (`binding child)
  | _ -> None

let bindings parent =
  ZI.filter_map classify_binding_opt parent

let simple_content elem =
  elem.Q.last_text_inside

let raise_elem = Q.raise_elem
let log_elem = Q.log_elem
let as_xml x = x

let selection_children sel =
  sel |> ZI.filter_map (fun child ->
    match ZI.tag child with
    | Some "requires" -> Some (`requires child)
    | Some "restricts" -> Some (`restricts child)
    | Some "command" -> Some (`command child)
    | _ -> classify_binding_opt child
  )

let command_children sel =
  sel |> ZI.filter_map (fun child ->
    match ZI.tag child with
    | Some "requires" -> Some (`requires child)
    | Some "restricts" -> Some (`restricts child)
    | Some "runner" -> Some (`runner child)
    | _ -> classify_binding_opt child
  )
