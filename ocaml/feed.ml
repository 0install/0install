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

type binding
type dependency
type command

type properties = {
  attrs : string AttrMap.t;
  requires : dependency list;
  bindings : binding list;
  commands : command StringMap.t;
}

type implementation = {
  qdom : Qdom.element;
  props : properties;
}

type feed = {
  root : Qdom.element;
  name : string;
  implementations : implementation StringMap.t;
}

(* Some constant strings used in the XML (to avoid typos) *)
let elem_group = "group"
let elem_implementation = "implementation"
let elem_package_implementation = "package-implementation"

let attr_stability = "stability"
let attr_version = "version"
let attr_version_modifier = "version-modifier"

let value_testing = "testing"

let make_command _name _path : command = failwith "TODO" (* TODO *)

let get_attr_opt key map =
  try Some (AttrMap.find ("", key) map)
  with Not_found -> None

let parse root =
  (* TODO: if-0install-version *)
  let () = match ZI.tag root with
  | Some "interface" | Some "feed" -> ()
  | _ -> Qdom.raise_elem "Expected <interface>, not " root in
  (* TODO: main on root? *)
  (* TODO: min-injector-version *)
  (* TODO: URI, local-path *)

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
    let impl = {
      qdom = node;
      props = !s;
    } in
    implementations := StringMap.add id impl !implementations
  in

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
                let new_command = make_command command_name path in
                s := {!s with commands = StringMap.add command_name new_command !s.commands} in
          handle_old_command "main" "run";
          handle_old_command "self-test" "test";

          (* TODO: commands, dependencies, bindings *)

          (* TODO: compile:command *)
          let add_attr old (name_pair, value) =
            AttrMap.add name_pair value old in
          s := {!s with attrs = List.fold_left add_attr !s.attrs item.Qdom.attrs};

          match ZI.tag item with
          | Some "group" -> process_group !s item
          | Some "implementation" -> process_impl item !s
          | Some "package-implementation" -> () (* TODO *)
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
    name = (
      match !name with
      | None -> Qdom.raise_elem "Missing <name> in" root
      | Some name -> name
    );
    root;
    implementations = !implementations;
  }

let get_attr_ex name (impl:implementation) =
  try AttrMap.find ("", name) impl.props.attrs
  with Not_found -> Qdom.raise_elem "Missing '%s' attribute for " name impl.qdom

let get_version_string (impl:implementation) =
  get_attr_ex "version" impl

(* TODO: sort by (parsed) version *)
let get_implementations feed =
  StringMap.fold (fun _k impl xs -> impl :: xs) feed.implementations []
