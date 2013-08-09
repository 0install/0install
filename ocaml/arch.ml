(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** OS and CPU types. *)

open Support.Common

(* Maps machine type names used in packages to their Zero Install versions
   (updates to this might require changing the reverse Java mapping) *)
let canonical_machines = List.fold_left (fun map (k, v) -> StringMap.add k v map) StringMap.empty [
  ("all", "*");
  ("any", "*");
  ("noarch", "*");
  ("(none)", "*");
  ("x86_64", "x86_64");
  ("amd64", "x86_64");
  ("i386", "i386");
  ("i486", "i486");
  ("i586", "i586");
  ("i686", "i686");
  ("ppc64", "ppc64");
  ("ppc", "ppc");
]

(** Return the canonical name for this CPU, or None if we don't know one. *)
let canonical_machine s =
  try Some (StringMap.find (String.lowercase s) canonical_machines)
  with Not_found -> None

let host_machine (system : system) =
  let m = (system#platform ()).Platform.machine in
  match canonical_machine m with
  | Some canonical -> canonical
  | None -> log_warning "Unknown machine type '%s'" m; m

let none_if_star = function
  | "*" -> None
  | v -> Some v

(** Parse a (canonical) arch, as found in 0install feeds. *)
let parse_arch arch =
  match Str.bounded_split_delim Support.Utils.re_dash arch 0 with
  | [os; machine] -> (none_if_star os, none_if_star machine)
  | _ -> raise_safe "Invalid architecture '%s'" arch
