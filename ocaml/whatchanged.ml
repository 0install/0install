(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install whatchanged" command *)

open Zeroinstall.General
open Support.Common
module Qdom = Support.Qdom

let show_changes (system:system) old_selections new_selections =
  let changes = ref false in

  let old_index = Zeroinstall.Selections.make_selection_map old_selections in
  let new_index = Zeroinstall.Selections.make_selection_map new_selections in

  let lookup name index =
    try Some (StringMap.find name index)
    with Not_found -> None in

  let v sel = ZI.get_attribute "version" sel in

  let print fmt = Support.Utils.print system fmt in

  ZI.iter_with_name old_selections "selection" ~f:(fun old_sel ->
    let iface = ZI.get_attribute "interface" old_sel in
    match lookup iface new_index with
    | None ->
        print "No longer used: %s" iface;
        changes := true
    | Some new_sel ->
        if (v old_sel) <> (v new_sel) then (
          print "%s: %s -> %s" iface (v old_sel) (v new_sel);
          changes := true
        )
  );

  ZI.iter_with_name new_selections "selection" ~f:(fun new_sel ->
    let iface = ZI.get_attribute "interface" new_sel in
    if not (StringMap.mem iface old_index) then (
      print "%s: new -> %s" iface (v new_sel);
      changes := true
    )
  );
  
  !changes
