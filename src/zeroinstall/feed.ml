(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing feeds *)

open Support
open Support.Common
module Q = Support.Qdom
module U = Support.Utils
open Constants

module AttrMap = Support.Qdom.AttrMap

type t = {
  url : Feed_url.non_distro_feed;
  root : [`Feed] Element.t;
  name : string;
  implementations : 'a. ([> `Cache_impl of Impl.cache_impl | `Local_impl of filepath] as 'a) Impl.t XString.Map.t;
  imported_feeds : Feed_import.t list;

  (* The URI of the interface that replaced the one with the URI of this feed's URL.
     This is the value of the feed's <replaced-by interface'...'/> element. *)
  replacement : string option;

  package_implementations : ([`Package_impl] Element.t * Impl.properties) list;
}

let create_impl system ~local_dir state node =
  let open Impl in
  let s = ref state in

  let set_attr name value =
    let new_attrs = AttrMap.add_no_ns name value !s.Impl.attrs in
    s := {!s with Impl.attrs = new_attrs} in

  let get_required_attr name =
    AttrMap.get_no_ns name !s.attrs |? lazy (Element.raise_elem "Missing attribute '%s' on" name node) in

  let id = Element.id node in

  let () =
    match local_dir with
    | None ->
        if AttrMap.mem ("", FeedAttr.local_path) !s.attrs then
          Element.raise_elem "local-path in non-local feed! " node;
    | Some dir ->
        let use rel_path =
          if Filename.is_relative rel_path then
            set_attr FeedAttr.local_path @@ Support.Utils.abspath system @@ dir +/ rel_path
          else
            set_attr FeedAttr.local_path rel_path in
        match AttrMap.get_no_ns FeedAttr.local_path !s.attrs with
        | Some path -> use path
        | None ->
            if XString.starts_with id "/" || XString.starts_with id "." then
              use id in

  (* version-modifier *)
  AttrMap.get_no_ns FeedAttr.version_modifier !s.attrs
  |> if_some (fun modifier ->
      let real_version = get_required_attr FeedAttr.version ^ modifier in
      let new_attrs = AttrMap.add_no_ns FeedAttr.version real_version (AttrMap.remove ("", FeedAttr.version_modifier) !s.attrs) in
      s := {!s with attrs = new_attrs}
  );

  let get_prop key =
    AttrMap.get_no_ns key !s.attrs |? lazy (Element.raise_elem "Missing attribute '%s' on" key node) in

  let (os, machine) =
    try Arch.parse_arch @@ default "*-*" @@ AttrMap.get_no_ns "arch" !s.attrs
    with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... processing %a" Element.pp node in

  let stability =
    match AttrMap.get_no_ns FeedAttr.stability !s.attrs with
    | None -> Stability.Testing
    | Some s -> Stability.of_string ~from_user:false s in

  let impl_type =
    match AttrMap.get_no_ns FeedAttr.local_path !s.attrs with
    | Some local_path ->
        assert (local_dir <> None);
        `Local_impl local_path
    | None ->
        let retrieval_methods = Element.retrieval_methods node in
        `Cache_impl { digests = Stores.get_digests node; retrieval_methods; } in

  let impl =
    Impl.make
      ~elem:node
      ~props:{!s with requires = List.rev !s.requires}
      ~os ~machine
      ~stability
      ~version:(Version.parse (get_prop FeedAttr.version))
      impl_type
  in
  (id, impl)

let process_group_properties ~local_dir state item =
  let open Impl in
  let s = ref state in
  (* We've found a group or implementation. Scan for dependencies,
      bindings and commands. Doing this here means that:
      - We can share the code for groups and implementations here.
      - The order doesn't matter, because these get processed first.
      A side-effect is that the document root cannot contain these. *)

  (* Upgrade main='...' to <command name='run' path='...'> etc *)
  let add_command ?path ?shell_command name =
    let new_command =
      Element.make_command ~source_hint:(Some item) ?path ?shell_command name
      |> Impl.parse_command local_dir in
    s := {!s with commands = XString.Map.add name new_command !s.commands} in

  Element.main item |> if_some (fun path -> add_command ~path "run");
  Element.self_test item |> if_some (fun path -> add_command ~path "test");
  Element.compile_command item |> if_some (fun shell_command -> add_command ~shell_command "compile");

  let new_bindings = ref [] in

  Element.deps_and_bindings item |> List.iter (function
    | `Requires child  | `Restricts child ->
        let req = Impl.parse_dep local_dir child in
        s := {!s with requires = req :: !s.requires}
    | `Command child ->
        let command_name = Element.command_name child in
        s := {!s with commands = XString.Map.add command_name (Impl.parse_command local_dir child) !s.commands}
    | #Element.binding as child ->
        new_bindings := Element.element_of_binding child :: !new_bindings
    | _ -> ()
  );

  if !new_bindings <> [] then
    s := {!s with bindings = !s.bindings @ (List.rev !new_bindings)};

  let new_attrs = !s.attrs |> AttrMap.add_all (Element.as_xml item).Q.attrs in

  {!s with
    attrs = new_attrs;
    requires = !s.requires;
  }

let default_attrs ~url =
  AttrMap.empty
    |> AttrMap.add_no_ns FeedAttr.stability FeedAttr.value_testing
    |> AttrMap.add_no_ns FeedAttr.from_feed url

let parse_implementations (system:#filesystem) root_attrs root local_dir =
  let open Impl in
  let implementations = ref XString.Map.empty in
  let package_implementations = ref [] in

  let process_impl node (state:Impl.properties) =
    let (id, impl) = create_impl system ~local_dir state node in
    if XString.Map.mem id !implementations then
      Element.raise_elem "Duplicate ID '%s' in:" id node;
    implementations := XString.Map.add id impl !implementations
  in

  let rec process_group state group =
    Element.group_children group |> List.iter (function
      | `Group item -> process_group (process_group_properties ~local_dir state item) (item :> [`Feed | `Group] Element.t)
      | `Implementation item -> process_impl item (process_group_properties ~local_dir state item)
      | `Package_impl item ->
          package_implementations := (item, (process_group_properties ~local_dir state item)) :: !package_implementations
    )
  in

  (* 'main' on the <interface> (deprecated) *)
  let root_commands = match Element.main root with
    | None -> XString.Map.empty
    | Some path ->
        let new_command =
          Element.make_command ~source_hint:(Some root) ~path "run"
          |> Impl.parse_command local_dir in
        XString.Map.singleton "run" new_command in

  let root_state = {
    attrs = root_attrs;
    bindings = [];
    commands = root_commands;
    requires = [];
  } in
  process_group root_state (root :> [`Feed | `Group] Element.t);

  (!implementations, !package_implementations)

let parse system root feed_local_path =
  let url =
    match feed_local_path with
    | None -> Element.uri root |? lazy (Element.raise_elem "Missing 'uri' attribute on non-local feed:" root)
    | Some path -> path in

  let local_dir =
    match feed_local_path with
    | None -> None
    | Some path -> Some (Filename.dirname path) in

  (* For local feeds, make relative paths absolute. For cached feeds, reject paths. *)
  let normalise_url raw_url elem =
    if XString.starts_with raw_url "http://" || XString.starts_with raw_url "https://" then
      raw_url
    else (
      match local_dir with
      | Some dir -> U.normpath @@ dir +/ raw_url
      | None -> Element.raise_elem "Relative URI '%s' in non-local feed" raw_url elem
    ) in

  let parse_feed_import node =
    let (feed_os, feed_machine) = match Element.arch node with
    | None -> (None, None)
    | Some arch -> Arch.parse_arch arch in

    let feed_langs = match Element.langs node with
    | None -> None
    | Some langs -> Some (Str.split XString.re_space langs) in

    { Feed_import.
      src = Feed_url.parse_non_distro @@ normalise_url (Element.src node) node;
      os = feed_os;
      machine = feed_machine;
      langs = feed_langs;
      ty = Feed_import;
    } in

  let name = ref None in
  let replacement = ref None in
  let imported_feeds = ref [] in

  Element.feed_metadata root |> List.iter (function
    | `Name node -> name := Some (Element.simple_content node)
    | `Feed_import import -> imported_feeds := parse_feed_import import :: !imported_feeds
    | `Replaced_by node ->
        if !replacement = None then
          replacement := Some (normalise_url (Element.interface node) node)
        else
          Element.raise_elem "Multiple replacements!" node
    | `Feed_for _ | `Category _ | `Needs_terminal _ | `Icon _ | `Homepage _ -> ()
  );

  let implementations, package_implementations =
    parse_implementations system (default_attrs ~url) root local_dir in

  {
    url = Feed_url.parse_non_distro url;
    name = (
      match !name with
      | None -> Element.raise_elem "Missing <name> in" root
      | Some name -> name
    );
    root;
    replacement = !replacement;
    implementations = implementations;
    package_implementations = package_implementations;
    imported_feeds = !imported_feeds;
  }

let get_feed_targets feed =
  Element.feed_metadata feed.root |> List.filter_map (function
    | `Feed_for f -> Some (Element.interface f)
    | _ -> None
  )

let get_category feed =
  Element.feed_metadata feed.root |> U.first_match (function
    | `Category c -> Some (Element.simple_content c)
    | _ -> None
  )

let needs_terminal feed =
  Element.feed_metadata feed.root |> List.exists (function
    | `Needs_terminal _ -> true
    | _ -> false
  )

let icons feed =
  Element.feed_metadata feed.root |> List.filter_map (function
    | `Icon icon -> Some icon
    | _ -> None
  )

let get_summary langs feed = Element.get_summary langs feed.root
let get_description langs feed = Element.get_description langs feed.root
let url t = t.url
let zi_implementations t = t.implementations
let package_implementations t = t.package_implementations
let replacement t = t.replacement
let imported_feeds t = t.imported_feeds
let name t = t.name
let pp_url f t = Feed_url.pp f t.url
let root t = t.root
