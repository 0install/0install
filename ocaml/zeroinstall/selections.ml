(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** <selection> elements *)

open Support.Common
open General

module U = Support.Utils
module Q = Support.Qdom
module FeedAttr = Constants.FeedAttr

type impl_source =
  | CacheSelection of Stores.digest list
  | LocalSelection of string
  | PackageSelection
;;

let re_initial_slash = Str.regexp "^/";;
let re_package = Str.regexp "^package:";;

let make_selection elem =
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
;;

let get_path system stores elem =
  match make_selection elem with
  | PackageSelection -> None
  | LocalSelection path -> Some path
  | CacheSelection digests -> Some (Stores.lookup_any system digests stores)
;;

(** Create a map from interface URI to <selection> elements. *)
let make_selection_map sels =
  let add_selection m sel =
    StringMap.add (ZI.get_attribute "interface" sel) sel m
  in ZI.fold_left ~f:add_selection StringMap.empty sels "selection"

let to_latest_format root =
  ZI.check_tag "selections" root;
  let (good_children, old_commands) = root.Q.child_nodes |> List.partition (fun child ->
    ZI.tag child <> Some "command"
  ) in
  if old_commands <> [] then (
    try
      (* 0launch 0.52 to 1.1 *)
      let iface = ref (Some (ZI.get_attribute "interface" root)) in
      let index = make_selection_map root in
      root.Q.child_nodes <- good_children;
      Q.set_attribute "command" "run" root;
      old_commands |> List.iter (fun command ->
        Q.set_attribute "name" "run" command;
        let current_iface = !iface |? lazy (Q.raise_elem "No additional command expected here!" command) in
        let sel = U.find_opt current_iface index |? lazy (Q.raise_elem "Missing selection for '%s' needed by" current_iface command) in
        sel.Q.child_nodes <- command :: sel.Q.child_nodes;
        match Command.get_runner command with
        | None -> iface := None
        | Some runner -> iface := Some (ZI.get_attribute "interface" runner)
      )
    with Safe_exception _ as ex -> reraise_with_context ex "... migrating from old selections format"
  );
  root

let load_selections system path =
  let root = Q.parse_file system path in
  to_latest_format root

let get_feed elem =
  ZI.check_tag "selection" elem;
  match ZI.get_attribute_opt "from-feed" elem with
  | None -> ZI.get_attribute "interface" elem
  | Some feed -> feed
;;

(** If [distro] is set then <package-implementation>s are included. Otherwise, they are ignored. *)
let get_unavailable_selections config ?distro sels =
  let missing = ref [] in

  let needs_download elem =
    match make_selection elem with
    | LocalSelection _ -> false
    | CacheSelection digests -> None = Stores.lookup_maybe config.system digests config.stores
    | PackageSelection ->
        match distro with
        | None -> false
        | Some distro -> not @@ Distro.is_installed config distro elem
  in
  let check sel =
    if needs_download sel then (
      Q.log_elem Support.Logging.Info "Missing selection of %s:" (ZI.get_attribute "interface" sel) sel;
      missing := sel :: !missing
    )
  in

  ZI.iter_with_name ~f:check sels "selection";

  !missing

(** Get the direct dependencies (excluding any inside commands) of this <selection> or <command>. *)
let get_dependencies ~restricts elem =
  ZI.filter_map elem ~f:(fun node ->
    match ZI.tag node with
    | Some "requires" | Some "runner" -> Some node
    | Some "restricts" when restricts -> Some node
    | _ -> None
  )

(** Collect all the commands needed by this dependency. *)
let get_required_commands dep =
  let commands =
    ZI.filter_map dep ~f:(fun node ->
      match Binding.parse_binding node with
      | Some binding -> Binding.get_command binding
      | None -> None
    ) in
  match ZI.tag dep with
  | Some "runner" -> (default "run" @@ ZI.get_attribute_opt "command" dep) :: commands
  | Some "requires" | Some "restricts" -> commands
  | _ -> Q.raise_elem "Not a dependency: " dep

let get_id sel = Feed.({
  id = ZI.get_attribute FeedAttr.id sel;
  feed = ZI.get_attribute_opt FeedAttr.from_feed sel |? lazy (ZI.get_attribute FeedAttr.interface sel);
})
