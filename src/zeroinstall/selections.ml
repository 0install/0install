(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
open Support.Common

module U = Support.Utils
module Q = Support.Qdom

type selection = [`Selection] Element.t

type impl_source =
  | CacheSelection of Manifest.digest list
  | LocalSelection of string
  | PackageSelection

type impl = selection
type command_name = string

type role = {
  iface : Sigs.iface_uri;
  source : bool;
}

module Role = struct
  type t = role

  let pp f = function
    | {iface; source = false} -> Format.pp_print_string f iface
    | {iface; source = true} -> Format.fprintf f "%s#source" iface

  (* Sort the interfaces by URI so we have a stable output. *)
  let compare role_a role_b =
    match String.compare role_a.iface role_b.iface with
    | 0 -> compare role_a.source role_b.source
    | x -> x
end

module RoleMap = Map.Make(Role)

type t = {
  root : [`Selections] Element.t;
  index : selection RoleMap.t;
}

type requirements = {
  role : Role.t;
  command : command_name option;
}

type command = [`Command] Element.t

type dependency = [`Requires | `Runner] Element.t

type dep_info = {
  dep_role : Role.t;
  dep_importance : [ `Essential | `Recommended | `Restricts ];
  dep_required_commands : command_name list;
}

let to_map t = t.index

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

let get_selected role sels = RoleMap.find_opt role sels.index

let get_selected_ex role sels =
  get_selected role sels
  |? lazy (Safe_exn.failf "Role '%a' not found in selections!" Role.pp role)

let root_role sels =
  let iface = root_iface sels in
  let source = Element.source sels.root
    |? lazy (
      (* This is an old (0install < 2.8) selections document, with no source attribute. *)
      RoleMap.find_opt {iface; source = true} sels.index <> None
    ) in
  {iface; source}

let root_sel sels =
  let role = root_role sels in
  get_selected role sels |? lazy (Safe_exn.failf "Can't find a selection for the root (%a)!" Role.pp role)

let requirements sels = {role = root_role sels; command = root_command sels}

let iter fn sels = RoleMap.iter fn sels.index

(** Create a map from roles to <selection> elements. *)
let make_selection_map sels =
  Element.selections sels |> List.fold_left (fun m sel ->
    let iface = Element.interface sel in
    let machine = Element.arch sel |> pipe_some (fun arch -> snd (Arch.parse_arch arch)) in
    let source = Arch.is_src machine in
    RoleMap.add {iface; source} sel m
  ) RoleMap.empty

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

(* Return all bindings in document order *)
let collect_bindings t =
  let bindings = ref [] in

  let process_dep dep =
    let dep_role = {iface = Element.interface dep; source = Element.source dep |> default false} in
    if RoleMap.mem dep_role t.index then (
      let add_role b = (dep_role, b) in
      bindings := List.map add_role (Element.bindings dep) @ !bindings
    ) in
  let process_command role command =
    Element.command_children command |> List.iter (function
      | `Requires r -> process_dep r
      | `Runner r -> process_dep r
      | `Restricts r -> process_dep r
      | #Element.binding as binding -> bindings := (role, binding) :: !bindings
    ) in
  let process_impl role parent =
    Element.deps_and_bindings parent |> List.iter (function
      | `Requires r -> process_dep r
      | `Restricts r -> process_dep r
      | `Command c -> process_command role c
      | #Element.binding as binding -> bindings := (role, binding) :: !bindings
    ) in

  t |> iter (fun role node ->
    try process_impl role node
    with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... getting bindings from selection %a" Role.pp role
  );
  List.rev !bindings

(** Collect all the commands needed by this dependency. *)
let get_required_commands dep =
  let commands =
    Element.bindings dep |> List.filter_map  (fun node ->
      Binding.parse_binding node |> Binding.get_command
    ) in
  match Element.classify_dep dep with
  | `Runner runner -> (default "run" @@ Element.command runner) :: commands
  | `Requires _ | `Restricts _ -> commands

let make_deps children =
  let self_commands = ref [] in
  let deps = children |> List.filter_map (function
    | `Requires r -> Some (r :> dependency)
    | `Runner r -> Some (r :> dependency)
    | #Element.binding as b ->
        Binding.parse_binding b |> Binding.get_command |> if_some (fun name ->
          self_commands := name :: !self_commands
        );
        None
    | `Restricts _ | `Command _ -> None
  ) in
  (deps, !self_commands)

let dep_info elem = {
    dep_role = {iface = Element.interface elem; source = Element.source elem |> default false};
    dep_importance = Element.importance elem;
    dep_required_commands = get_required_commands elem;
  }

let requires _role impl = make_deps (Element.deps_and_bindings impl)
let command_requires _role command = make_deps (Element.command_children command)
let get_command sel name = Element.get_command name sel

let selected_commands sel =
  Element.deps_and_bindings sel |> List.filter_map (function
      | `Command c -> Some (Element.command_name c)
      | _ -> None
    )
