(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing feeds *)

open General
open Support.Common
module Qdom = Support.Qdom

module AttrType =
  struct
    type t = Xmlm.name

    let compare a b = compare a b
  end

module AttrMap = Map.Make(AttrType)

type importance =
  | Dep_essential       (* Must select a version of the dependency *)
  | Dep_recommended     (* Prefer to select a version, if possible *)
  | Dep_restricts       (* Just adds restrictions without expressing any opinion *)

type restriction = (string * (implementation -> bool))

and binding = Qdom.element

and dependency = {
  dep_qdom : Qdom.element;
  dep_importance : importance;
  dep_iface: iface_uri;
  dep_restrictions: restriction list;
  dep_required_commands: string list;
}

and command = {
  command_qdom : Qdom.element;
  command_requires : dependency list;
  (* command_bindings : binding list; - not needed by solver; just copies the element *)
}

and properties = {
  attrs : string AttrMap.t;
  requires : dependency list;
  bindings : binding list;
  commands : command StringMap.t;
}

and implementation = {
  qdom : Qdom.element;
  props : properties;
  os : string option;           (* Required OS; the first part of the 'arch' attribute. None for '*' *)
  machine : string option;      (* Required CPU; the second part of the 'arch' attribute. None for '*' *)
  parsed_version : Versions.parsed_version;
}

type stability =
  | Insecure
  | Buggy
  | Developer
  | Testing
  | Stable
  | Packaged
  | Preferred

let parse_stability ~from_user s =
  let if_from_user l =
    if from_user then l else raise_safe "Stability '%s' not allowed here" s in
  match s with
  | "insecure" -> Insecure
  | "buggy" -> Buggy
  | "developer" -> Developer
  | "testing" -> Testing
  | "stable" -> Stable
  | "packaged" -> if_from_user Packaged
  | "preferred" -> if_from_user Preferred
  | x -> raise_safe "Unknown stability level '%s'" x

type feed = {
  url : string;
  root : Qdom.element;
  name : string;
  implementations : implementation StringMap.t;
  package_implementations : (Qdom.element * properties) list;
}

(* Some constant strings used in the XML (to avoid typos) *)
let elem_group = "group"
let elem_implementation = "implementation"
let elem_package_implementation = "package-implementation"

let attr_id = "id"
let attr_stability = "stability"
let attr_importance = "importance"
let attr_version = "version"
let attr_version_modifier = "version-modifier"      (* This is stripped out and moved into attr_version *)

let value_testing = "testing"

let make_command doc name path : command =
  let elem = ZI.make doc "command" in
  elem.Qdom.attrs <- [(("", "name"), name); (("", "path"), path)];
  {
    command_qdom = elem;
    command_requires = [];
  }

let get_attr_opt key map =
  try Some (AttrMap.find ("", key) map)
  with Not_found -> None

let parse_version_element elem =
  let before = ZI.get_attribute_opt "before" elem in
  let not_before = ZI.get_attribute_opt "not-before" elem in
  let s = match before, not_before with
  | None, None -> "no restriction!"
  | Some low, None -> low ^ " <= version"
  | None, Some high -> "version < " ^ high
  | Some low, Some high -> low ^ " <= version < " ^ high in
  let test = Versions.make_range_restriction not_before before in
  (s, (fun impl -> test (impl.parsed_version)))

let parse_dep dep =
  let iface = ZI.get_attribute "interface" dep in
  (* TODO: relative paths *)

  (* TODO: distribution *)

  let commands = ref StringSet.empty in
  let restrictions = ZI.filter_map dep ~f:(fun child ->
    match ZI.tag child with
    | Some "version" -> Some (parse_version_element child)
    | Some _ -> (
        match Binding.parse_binding child with
        | Some binding -> (
            match Binding.get_command binding with
            | None -> ()
            | Some name -> commands := StringSet.add name !commands
        )
        | None -> ()
    ); None
    | _ -> None
  ) in

  let restrictions = match ZI.get_attribute_opt "version" dep with
    | None -> restrictions
    | Some expr -> (
        try
          let test = Versions.parse_expr expr in
          (expr, fun impl -> test (impl.parsed_version))
        with Safe_exception (ex_msg, _) as ex ->
          let msg = Printf.sprintf "Can't parse version restriction '%s': %s" expr ex_msg in
          log_warning ~ex:ex "%s" msg;
          (expr, fun _ -> false)
        ) :: restrictions
  in

  if ZI.tag dep = Some "runner" then (
    commands := StringSet.add (default "run" @@ ZI.get_attribute_opt "command" dep) !commands
  );

  let importance =
    if ZI.tag dep = Some "restricts" then Dep_restricts
    else (
      match ZI.get_attribute_opt attr_importance dep with
      | None | Some "essential" -> Dep_essential
      | _ -> Dep_recommended
    ) in

  {
    dep_qdom = dep;
    dep_iface = iface;
    dep_restrictions = restrictions;
    dep_required_commands = StringSet.elements !commands;
    dep_importance = importance;
  }

let parse_command elem : command =
  let deps = ref [] in

  ZI.iter elem ~f:(fun child ->
    match ZI.tag child with
    | Some "requires" | Some "restricts" | Some "runner" ->
        deps := parse_dep child :: !deps
    | _ -> ()
  );

  {
    command_qdom = elem;
    command_requires = !deps;
  }

let parse root local_path =
  (* TODO: if-0install-version *)
  let () = match ZI.tag root with
  | Some "interface" | Some "feed" -> ()
  | _ ->
      ZI.check_ns root;
      Qdom.raise_elem "Expected <interface>, not" root in
  (* TODO: main on root? *)
  (* TODO: min-injector-version *)

  let url =
    match local_path with
    | None -> ZI.get_attribute "uri" root
    | Some path -> path in                       (* TODO: local_dir *)

  let name = ref None in
  let implementations = ref StringMap.empty in

  ZI.iter root ~f:(fun node ->
    match ZI.tag node with
    | Some "name" -> name := Some (Qdom.simple_content node)
    | _ -> ()   (* TODO: process <feed> too, at least *)
  );

  let process_impl node (state:properties) =
    let s = ref state in

    let get_required_attr name =
      try AttrMap.find ("", name) !s.attrs
      with Not_found -> Qdom.raise_elem "Missing attribute '%s' on" name node in

    let id = ZI.get_attribute "id" node in
    (* TODO local-path *)
    if StringMap.mem id !implementations then
      Qdom.raise_elem "Duplicate ID '%s' in:" id node;
    (* version-modifier *)
    let () = match get_attr_opt attr_version_modifier !s.attrs with
    | Some modifier ->
        let real_version = get_required_attr attr_version ^ modifier in
        let new_attrs = AttrMap.add ("", attr_version) real_version (AttrMap.remove ("", attr_version_modifier) !s.attrs) in
        s := {!s with attrs = new_attrs}
    | None -> () in
    (* TODO: retrieval methods *)
    let get_prop key =
      match get_attr_opt key !s.attrs with
      | Some value -> value
      | None -> Qdom.raise_elem "Missing attribute '%s' on" key node in

    let (os, machine) =
      try Arch.parse_arch @@ default "*-*" @@ get_attr_opt "arch" !s.attrs
      with Safe_exception _ as ex -> reraise_with_context ex "... processing %s" (Qdom.show_with_loc node) in

    let impl = {
      qdom = node;
      props = !s;
      os;
      machine;
      parsed_version = Versions.parse_version (get_prop attr_version);
    } in
    implementations := StringMap.add id impl !implementations
  in

  let package_implementations = ref [] in

  let rec process_group state (group:Qdom.element) =
    ZI.iter group ~f:(fun item ->
      match ZI.tag item with
      | Some "group" | Some "implementation" | Some "package-implementation" -> (
          let s = ref state in
          (* We've found a group or implementation. Scan for dependencies,
             bindings and commands. Doing this here means that:
             - We can share the code for groups and implementations here.
             - The order doesn't matter, because these get processed first.
             A side-effect is that the document root cannot contain these. *)

          (* Upgrade main='...' to <command name='run' path='...'> etc *)
          let handle_old_command attr_name command_name =
            match ZI.get_attribute_opt attr_name item with
            | None -> ()
            | Some path ->
                let new_command = make_command root.Qdom.doc command_name path in
                s := {!s with commands = StringMap.add command_name new_command !s.commands} in
          handle_old_command "main" "run";
          handle_old_command "self-test" "test";

          ZI.iter item ~f:(fun child ->
            match ZI.tag child with
            | Some "requires" | Some "restricts" ->
                let req = parse_dep child in
                s := {!s with requires = req :: !s.requires}
            | Some "command" ->
                let command_name = ZI.get_attribute "name" child in
                s := {!s with commands = StringMap.add command_name (parse_command child) !s.commands}
            | Some tag when Binding.is_binding tag ->
                s := {!s with bindings = child :: !s.bindings}
            | _ -> ()
          );

          (* TODO: compile:command *)
          let add_attr old (name_pair, value) =
            AttrMap.add name_pair value old in

          s := {!s with
            attrs = List.fold_left add_attr !s.attrs item.Qdom.attrs;
            requires = List.rev !s.requires;
          };

          match ZI.tag item with
          | Some "group" -> process_group !s item
          | Some "implementation" -> process_impl item !s
          | Some "package-implementation" -> package_implementations := (item, !s) :: !package_implementations
          | _ -> assert false
      )
      | _ -> ()
    )
  in

  let root_attrs = AttrMap.singleton ("", attr_stability) value_testing in
  let root_state = {
    attrs = root_attrs;
    bindings = [];
    commands = StringMap.empty;
    requires = [];
  } in
  process_group root_state root;

  {
    url;
    name = (
      match !name with
      | None -> Qdom.raise_elem "Missing <name> in" root
      | Some name -> name
    );
    root;
    implementations = !implementations;
    package_implementations = !package_implementations;
  }

let get_attr_ex name (impl:implementation) =
  try AttrMap.find ("", name) impl.props.attrs
  with Not_found -> Qdom.raise_elem "Missing '%s' attribute for " name impl.qdom

let get_version (impl:implementation) =
  try Versions.parse_version @@ get_attr_ex "version" impl
  with Safe_exception _ as ex -> reraise_with_context ex "... in %s" (Qdom.show_with_loc impl.qdom)

(* Get all the implementations (note: only sorted by ID) *)
let get_implementations feed =
  StringMap.fold (fun _k impl xs -> impl :: xs) feed.implementations []
