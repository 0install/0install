(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** OS and CPU types. *)

open Support.Common

let none_if_star = function
  | "*" -> None
  | v -> Some v

(** Parse a (canonical) arch, as found in 0install feeds. *)
let parse_arch arch =
  match Str.bounded_split_delim Support.Utils.re_dash arch 0 with
  | [os; machine] -> (none_if_star os, none_if_star machine)
  | _ -> raise_safe "Invalid architecture '%s'" arch

let format_arch os machine =
  let os_str = default "*" os in
  let machine_str = default "*" machine in
  os_str ^ "-" ^ machine_str

let get_os_ranks os =
  let ranks = ref @@ StringMap.singleton os 1 in  (* Binaries compiled for _this_ OS are best.. *)

  (* Assume everything supports POSIX except Windows (but Cygwin is POSIX) *)
  if os <> "Windows" then
    ranks := StringMap.add "POSIX" 2 !ranks;

  let () =
    match os with
    | "Cygwin" -> ranks := StringMap.add "Windows" 2 !ranks
    | "MacOSX" -> ranks := StringMap.add "Darwin" 2 !ranks
    | _ -> () in

  !ranks

type machine_group =
  | Machine_group_default     (* e.g. i686 *)
  | Machine_group_64          (* e.g. x86_64 *)

(* All chosen machine-specific implementations must come from the same group.
   Unlisted archs are in Machine_group_default. *)
let get_machine_group = function
  | "x86_64" | "ppc64" -> Machine_group_64
  | _ -> Machine_group_default

let get_machine_ranks ~multiarch machine =
  let ranks = ref @@ StringMap.singleton machine 1 in

  let compatible_machines =
    (* If target_machine appears in the first column of this table, all
       following machine types on the line will also run on this one
       (earlier ones preferred) *)
    match machine with
    | "i486"    -> [|"i386"|]
    | "i586"    -> [|"i486"; "i386"|]
    | "i686"    -> [|"i586"; "i486"; "i386"|]
    | "ppc"     -> [|"ppc32"|]
    | "x86_64" when multiarch -> [|"i686"; "i586"; "i486"; "i386"|]
    | "ppc64"  when multiarch -> [|"ppc"|]
    | _ -> [||] in

  for i = 0 to Array.length compatible_machines - 1 do
    ranks := StringMap.add compatible_machines.(i) (i + 2) !ranks
  done;

  !ranks
