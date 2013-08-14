(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing feeds *)

open General
open Support.Common
module Qdom = Support.Qdom
module U = Support.Utils

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

type package_impl = {
  package_distro : string;
  package_installed : bool;
}

type cache_impl = {
  digests : Stores.digest list;
  retrieval_methods : Qdom.element list;
}

type impl_type =
  | CacheImpl of cache_impl
  | LocalImpl of filepath
  | PackageImpl of package_impl

type restriction = (string * (implementation -> bool))

and binding = Qdom.element

and dependency = {
  dep_qdom : Qdom.element;
  dep_importance : importance;
  dep_iface: iface_uri;
  dep_restrictions: restriction list;
  dep_required_commands: string list;
  dep_if_os : string option;                (* The badly-named 'os' attribute *)
  dep_use : string option;                  (* Deprecated 'use' attribute *)
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
  stability : stability_level;
  os : string option;           (* Required OS; the first part of the 'arch' attribute. None for '*' *)
  machine : string option;      (* Required CPU; the second part of the 'arch' attribute. None for '*' *)
  parsed_version : Versions.parsed_version;
  impl_type : impl_type;
}

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

type feed_overrides = {
  last_checked : float option;
  user_stability : stability_level StringMap.t;
}

type feed_type =
  | Feed_import             (* A <feed> import element inside a feed *)
  | User_registered         (* Added manually with "0install add-feed" : save to config *)
  | Site_packages           (* Found in the site-packages directory : save to config for older versions, but flag it *)
  | Distro_packages         (* Found in native_feeds : don't save *)

type feed_import = {
  feed_src : string;

  feed_os : string option;          (* All impls requires this OS *)
  feed_machine : string option;     (* All impls requires this CPU *)
  feed_langs : string list option;  (* No impls for languages not listed *)
  feed_type: feed_type;
}

type feed = {
  url : string;
  root : Qdom.element;
  name : string;
  implementations : implementation StringMap.t;
  imported_feeds : feed_import list;

  (* The URI of the interface that replaced the one with the URI of this feed's URL.
     This is the value of the feed's <replaced-by interface'...'/> element. *)
  replacement : string option;

  package_implementations : (Qdom.element * properties) list;
}

(* Some constant strings used in the XML (to avoid typos) *)
let elem_group = "group"
let elem_implementation = "implementation"
let elem_package_implementation = "package-implementation"

let attr_id = "id"
let attr_main = "main"
let attr_self_test = "self-test"
let attr_stability = "stability"
let attr_importance = "importance"
let attr_version = "version"
let attr_version_modifier = "version-modifier"      (* This is stripped out and moved into attr_version *)
let attr_os= "os"
let attr_use = "use"
let attr_local_path = "local-path"
let attr_interface = "interface"
let attr_src = "src"
let attr_from_feed = "from-feed"
let attr_if_0install_version = "if-0install-version"
let attr_distribution = "distribution"

let value_testing = "testing"

let make_command doc name ?(new_attr="path") path : command =
  let elem = ZI.make doc "command" in
  elem.Qdom.attrs <- [(("", "name"), name); (("", new_attr), path)];
  {
    command_qdom = elem;
    command_requires = [];
  }

let make_distribtion_restriction distros =
  let check impl =
    ListLabels.exists (Str.split U.re_space distros) ~f:(fun distro ->
      match distro, impl.impl_type with
      | "0install", PackageImpl _ -> false
      | "0install", CacheImpl _ -> true
      | "0install", LocalImpl _ -> true
      | distro, PackageImpl {package_distro;_} -> package_distro = distro
      | _ -> false
    ) in
  ("distribution:" ^ distros, check)

let get_attr key impl =
  try AttrMap.find ("", key) impl.props.attrs
  with Not_found -> Qdom.raise_elem "Attribute '%s' not found on" key impl.qdom

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

let parse_dep local_dir dep =
  let iface =
    let raw_iface = ZI.get_attribute "interface" dep in
    if U.starts_with raw_iface "." then (
      match local_dir with
      | Some dir ->
          let iface = U.normpath @@ dir +/ raw_iface in
          Qdom.set_attribute "interface" iface dep;
          iface
      | None ->
          raise_safe "Relative interface URI '%s' in non-local feed" raw_iface
    ) else (
      raw_iface
    ) in

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

  let restrictions =
    match ZI.get_attribute_opt attr_distribution dep with
    | Some distros -> make_distribtion_restriction distros :: restrictions
    | None -> restrictions in

  {
    dep_qdom = dep;
    dep_iface = iface;
    dep_restrictions = restrictions;
    dep_required_commands = StringSet.elements !commands;
    dep_importance = importance;
    dep_use = ZI.get_attribute_opt attr_use dep;
    dep_if_os = ZI.get_attribute_opt attr_os dep;
  }

let parse_command local_dir elem : command =
  let deps = ref [] in

  ZI.iter elem ~f:(fun child ->
    match ZI.tag child with
    | Some "requires" | Some "restricts" | Some "runner" ->
        deps := parse_dep local_dir child :: !deps
    | _ -> ()
  );

  {
    command_qdom = elem;
    command_requires = !deps;
  }

let rec filter_if_0install_version node =
  let open Qdom in
  match Qdom.get_attribute_opt ("", attr_if_0install_version) node with
  | Some expr when not (Versions.parse_expr expr About.parsed_version) -> None
  | Some _expr -> Some {
    node with child_nodes = U.filter_map ~f:filter_if_0install_version node.child_nodes;
    attrs = List.remove_assoc ("", attr_if_0install_version) node.attrs
  }
  | None -> Some {
    node with child_nodes = U.filter_map ~f:filter_if_0install_version node.child_nodes;
  }

let parse system root feed_local_path =
  let root =
    match filter_if_0install_version root with
    | Some root -> root
    | None -> Qdom.raise_elem "Feed requires 0install version %s (we are %s):" (ZI.get_attribute attr_if_0install_version root) About.version root
  in

  let () = match ZI.tag root with
  | Some "interface" | Some "feed" -> ()
  | _ ->
      ZI.check_ns root;
      Qdom.raise_elem "Expected <interface>, not" root in

  let () = match ZI.get_attribute_opt "min-injector-version" root with
  | Some min_version when Versions.parse_version min_version > About.parsed_version ->
      Qdom.raise_elem "Feed requires 0install version %s or later (we are %s):" min_version About.version root
  | _ -> () in

  let url =
    match feed_local_path with
    | None -> ZI.get_attribute "uri" root
    | Some path -> path in

  let local_dir =
    match feed_local_path with
    | None -> None
    | Some path -> Some (Filename.dirname path) in

  (* For local feeds, make relative paths absolute. For cached feeds, reject paths. *)
  let normalise_url raw_url elem =
    if U.starts_with raw_url "http://" || U.starts_with raw_url "https://" then
      raw_url
    else (
      match local_dir with
      | Some dir -> U.normpath @@ dir +/ raw_url
      | None -> Qdom.raise_elem "Relative URI '%s' in non-local feed" raw_url elem
    ) in

  let parse_feed_import node =
    let (feed_os, feed_machine) = match ZI.get_attribute_opt "arch" node with
    | None -> (None, None)
    | Some arch -> Arch.parse_arch arch in

    let feed_langs = match ZI.get_attribute_opt "langs" node with
    | None -> None
    | Some langs -> Some (Str.split U.re_space langs) in

    {
      feed_src = normalise_url (ZI.get_attribute attr_src node) node;
      feed_os;
      feed_machine;
      feed_langs;
      feed_type = Feed_import;
    } in

  let name = ref None in
  let replacement = ref None in
  let implementations = ref StringMap.empty in
  let imported_feeds = ref [] in

  ZI.iter root ~f:(fun node ->
    match ZI.tag node with
    | Some "name" -> name := Some (Qdom.simple_content node)
    | Some "feed" -> imported_feeds := parse_feed_import node :: !imported_feeds
    | Some "replaced-by" ->
        if !replacement = None then
          replacement := Some (normalise_url (ZI.get_attribute attr_interface node) node)
        else
          Qdom.raise_elem "Multiple replacements!" node
    | _ -> ()
  );

  let process_impl node (state:properties) =
    let s = ref state in

    let set_attr name value =
      let new_attrs = AttrMap.add ("", name) value !s.attrs in
      s := {!s with attrs = new_attrs} in

    let get_required_attr name =
      try AttrMap.find ("", name) !s.attrs
      with Not_found -> Qdom.raise_elem "Missing attribute '%s' on" name node in

    let id = ZI.get_attribute "id" node in

    let () =
      match local_dir with
      | None -> ()
      | Some dir ->
          let use rel_path =
            if Filename.is_relative rel_path then
              set_attr attr_local_path @@ Support.Utils.abspath system @@ dir +/ rel_path
            else
              set_attr attr_local_path rel_path in
          match ZI.get_attribute_opt attr_local_path node with
          | Some path -> use path
          | None ->
              if Support.Utils.starts_with id "/" || Support.Utils.starts_with id "." then
                use id in

    if StringMap.mem id !implementations then
      Qdom.raise_elem "Duplicate ID '%s' in:" id node;
    (* version-modifier *)
    let () = match get_attr_opt attr_version_modifier !s.attrs with
    | Some modifier ->
        let real_version = get_required_attr attr_version ^ modifier in
        let new_attrs = AttrMap.add ("", attr_version) real_version (AttrMap.remove ("", attr_version_modifier) !s.attrs) in
        s := {!s with attrs = new_attrs}
    | None -> () in

    let get_prop key =
      match get_attr_opt key !s.attrs with
      | Some value -> value
      | None -> Qdom.raise_elem "Missing attribute '%s' on" key node in

    let (os, machine) =
      try Arch.parse_arch @@ default "*-*" @@ get_attr_opt "arch" !s.attrs
      with Safe_exception _ as ex -> reraise_with_context ex "... processing %s" (Qdom.show_with_loc node) in

    let stability =
      match get_attr_opt attr_stability !s.attrs with
      | None -> Testing
      | Some s -> parse_stability ~from_user:false s in

    let impl_type =
      try LocalImpl (AttrMap.find ("", attr_local_path) !s.attrs)
      with Not_found ->
        let retrieval_methods = List.filter Recipe.is_retrieval_method node.Qdom.child_nodes in
        CacheImpl { digests = Stores.get_digests node; retrieval_methods; } in

    let impl = {
      qdom = node;
      props = !s;
      os;
      machine;
      stability;
      parsed_version = Versions.parse_version (get_prop attr_version);
      impl_type;
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
          handle_old_command attr_main "run";
          handle_old_command attr_self_test "test";

          let () =
            match Qdom.get_attribute_opt (COMPILE_NS.ns, "command") item with
            | None -> ()
            | Some command ->
                let new_command = make_command root.Qdom.doc "compile" ~new_attr:"shell-command" command in
                s := {!s with commands = StringMap.add "compile" new_command !s.commands} in

          let new_bindings = ref [] in

          ZI.iter item ~f:(fun child ->
            match ZI.tag child with
            | Some "requires" | Some "restricts" ->
                let req = parse_dep local_dir child in
                s := {!s with requires = req :: !s.requires}
            | Some "command" ->
                let command_name = ZI.get_attribute "name" child in
                s := {!s with commands = StringMap.add command_name (parse_command local_dir child) !s.commands}
            | Some tag when Binding.is_binding tag ->
                new_bindings := child :: !new_bindings
            | _ -> ()
          );

          if !new_bindings <> [] then
            s := {!s with bindings = !s.bindings @ (List.rev !new_bindings)};

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

  let root_attrs = AttrMap.add ("", attr_from_feed) url @@ AttrMap.singleton ("", attr_stability) value_testing in

  (* 'main' on the <interface> (deprecated) *)
  let root_commands = match ZI.get_attribute_opt attr_main root with
    | None -> StringMap.empty
    | Some path ->
        let new_command = make_command root.Qdom.doc "run" path in
        StringMap.singleton "run" new_command in

  let root_state = {
    attrs = root_attrs;
    bindings = [];
    commands = root_commands;
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
    replacement = !replacement;
    implementations = !implementations;
    package_implementations = !package_implementations;
    imported_feeds = !imported_feeds;
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

let is_source impl = impl.machine = Some "src"

let get_command impl command_name : command =
  try StringMap.find command_name impl.props.commands
  with Not_found -> Qdom.raise_elem "Command '%s' not found in" command_name impl.qdom

(** Load per-feed extra data (last-checked time and preferred stability.
    Probably we should use a simple timestamp file for the last-checked time and attach
    the stability ratings to the interface, not the feed. *)
let load_feed_overrides config url =
  let open Support.Basedir in
  match load_first config.system (config_site +/ config_prog +/ "feeds" +/ Escape.pretty url) config.basedirs.config with
  | None -> { last_checked = None; user_stability = StringMap.empty }
  | Some path ->
      let root = Qdom.parse_file config.system path in

      let last_checked =
        match ZI.get_attribute_opt "last-checked" root with
        | None -> None
        | Some time -> Some (float_of_string time) in

      let stability = ref StringMap.empty in

      ZI.iter_with_name root "implementation" ~f:(fun impl ->
        let id = ZI.get_attribute "id" impl in
        match ZI.get_attribute_opt attr_stability impl with
        | None -> ()
        | Some s -> stability := StringMap.add id (parse_stability ~from_user:true s) !stability
      );

      { last_checked; user_stability = !stability; }

(** Does this feed contain any <pacakge-implementation> elements?
    i.e. is it worth asking the package manager for more information?
    If so, return the virtual feed's URL. *)
let get_distro_feed feed =
  if feed.package_implementations <> [] then
    Some ("distribution:" ^ feed.url)
  else
    None

(** The list of languages provided by this implementation. *)
let get_langs impl =
  let langs =
    try Str.split U.re_space @@ AttrMap.find ("", "langs") impl.props.attrs
    with Not_found -> ["en"] in
  Support.Utils.filter_map ~f:Locale.parse_lang langs

(** Is this implementation in the cache? *)
let is_available_locally config impl =
  match impl.impl_type with
  | PackageImpl {package_installed;_} -> package_installed
  | LocalImpl path -> config.system#file_exists path
  | CacheImpl {digests;_} ->
      match Stores.lookup_maybe config.system digests config.stores with
      | None -> false
      | Some _path -> true

let is_retrievable_without_network cache_impl =
  let ok_without_network elem =
    match Recipe.parse_retrieval_method elem with
    | Some recipe -> not @@ Recipe.recipe_requires_network recipe
    | None -> false in
  List.exists ok_without_network cache_impl.retrieval_methods
