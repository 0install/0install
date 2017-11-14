(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing feeds *)

open General
open Support.Common
module Q = Support.Qdom
module U = Support.Utils
open Constants

module AttrMap = Support.Qdom.AttrMap

type feed_overrides = {
  last_checked : float option;
  user_stability : Stability.t StringMap.t;
}

type feed_type =
  | Feed_import             (* A <feed> import element inside a feed *)
  | User_registered         (* Added manually with "0install add-feed" : save to config *)
  | Site_packages           (* Found in the site-packages directory : save to config for older versions, but flag it *)
  | Distro_packages         (* Found in native_feeds : don't save *)

type feed_import = {
  feed_src : Feed_url.non_distro_feed;

  feed_os : Arch.os option;           (* All impls requires this OS *)
  feed_machine : Arch.machine option; (* All impls requires this CPU *)
  feed_langs : string list option;    (* No impls for languages not listed *)
  feed_type: feed_type;
}

type feed = {
  url : Feed_url.non_distro_feed;
  root : [`Feed] Element.t;
  name : string;
  implementations : 'a. ([> `Cache_impl of Impl.cache_impl | `Local_impl of filepath] as 'a) Impl.t StringMap.t;
  imported_feeds : feed_import list;

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
            if Support.Utils.starts_with id "/" || Support.Utils.starts_with id "." then
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
    with Safe_exception _ as ex -> reraise_with_context ex "... processing %s" (Element.show_with_loc node) in

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
    s := {!s with commands = StringMap.add name new_command !s.commands} in

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
        s := {!s with commands = StringMap.add command_name (Impl.parse_command local_dir child) !s.commands}
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
  let implementations = ref StringMap.empty in
  let package_implementations = ref [] in

  let process_impl node (state:Impl.properties) =
    let (id, impl) = create_impl system ~local_dir state node in
    if StringMap.mem id !implementations then
      Element.raise_elem "Duplicate ID '%s' in:" id node;
    implementations := StringMap.add id impl !implementations
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
    | None -> StringMap.empty
    | Some path ->
        let new_command =
          Element.make_command ~source_hint:(Some root) ~path "run"
          |> Impl.parse_command local_dir in
        StringMap.singleton "run" new_command in

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
    if U.starts_with raw_url "http://" || U.starts_with raw_url "https://" then
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
    | Some langs -> Some (Str.split U.re_space langs) in

    {
      feed_src = Feed_url.parse_non_distro @@ normalise_url (Element.src node) node;
      feed_os;
      feed_machine;
      feed_langs;
      feed_type = Feed_import;
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

(* Get all the implementations (note: only sorted by ID) *)
let get_implementations feed =
  StringMap.map_bindings (fun _k impl -> impl) feed.implementations

(** Load per-feed extra data (last-checked time and preferred stability.
    Probably we should use a simple timestamp file for the last-checked time and attach
    the stability ratings to the interface, not the feed. *)
let load_feed_overrides config feed_url =
  match Paths.Config.(first (feed feed_url)) config.paths with
  | None -> { last_checked = None; user_stability = StringMap.empty }
  | Some path ->
      let root = Q.parse_file config.system path in

      let last_checked =
        match ZI.get_attribute_opt "last-checked" root with
        | None -> None
        | Some time -> Some (float_of_string time) in

      let stability = ref StringMap.empty in

      root |> ZI.iter ~name:"implementation" (fun impl ->
        let id = ZI.get_attribute "id" impl in
        match ZI.get_attribute_opt FeedConfigAttr.user_stability impl with
        | None -> ()
        | Some s -> stability := StringMap.add id (Stability.of_string ~from_user:true s) !stability
      );

      { last_checked; user_stability = !stability; }

let save_feed_overrides config feed_url overrides =
  let module B = Support.Basedir in
  let {last_checked; user_stability} = overrides in
  let feed_path = Paths.Config.(save_path (feed feed_url)) config.paths in

  let attrs =
    match last_checked with
    | None -> AttrMap.empty
    | Some last_checked -> AttrMap.singleton "last-checked" (Printf.sprintf "%.0f" last_checked) in
  let child_nodes = user_stability |> StringMap.map_bindings (fun id stability ->
    ZI.make "implementation" ~attrs:(
      AttrMap.singleton FeedAttr.id id
      |> AttrMap.add_no_ns FeedConfigAttr.user_stability (Stability.to_string stability)
    )
  ) in
  let root = ZI.make ~attrs ~child_nodes "feed-preferences" in
  feed_path |> config.system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
    Q.output (`Channel ch |> Xmlm.make_output) root;
  )

let update_last_checked_time config url =
  let overrides = load_feed_overrides config url in
  save_feed_overrides config url {overrides with last_checked = Some config.system#time}

let get_feed_targets feed =
  Element.feed_metadata feed.root |> U.filter_map (function
    | `Feed_for f -> Some (Element.interface f)
    | _ -> None
  )

let make_user_import feed_src = {
  feed_src = (feed_src :> Feed_url.non_distro_feed);
  feed_os = None;
  feed_machine = None;
  feed_langs = None;
  feed_type = User_registered;
}

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
  Element.feed_metadata feed.root |> U.filter_map (function
    | `Icon icon -> Some icon
    | _ -> None
  )

let get_summary langs feed = Element.get_summary langs feed.root
let get_description langs feed = Element.get_description langs feed.root
