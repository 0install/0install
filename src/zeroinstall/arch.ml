(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** OS and CPU types. *)

open Support
open Support.Common

type os = string
type machine = string
type arch = os option * machine option

type os_ranking = int XString.Map.t
type machine_ranking = int XString.Map.t

let none_if_star = function
  | "*" -> None
  | v -> Some v

let parse_machine = none_if_star
let parse_os = none_if_star

(** Parse a (canonical) arch, as found in 0install feeds. *)
let parse_arch arch =
  match Str.bounded_split_delim Support.XString.re_dash arch 0 with
  | [os; machine] -> (none_if_star os, none_if_star machine)
  | _ -> Safe_exn.failf "Invalid architecture '%s'" arch

let format_arch (os, machine) =
  let os_str = default "*" os in
  let machine_str = default "*" machine in
  os_str ^ "-" ^ machine_str

let get_os_ranks os =
  let ranks = ref @@ XString.Map.singleton os 1 in  (* Binaries compiled for _this_ OS are best.. *)

  (* Assume everything supports POSIX except Windows (but Cygwin is POSIX) *)
  if os <> "Windows" then
    ranks := XString.Map.add "POSIX" 2 !ranks;

  let () =
    match os with
    | "Cygwin" -> ranks := XString.Map.add "Windows" 2 !ranks
    | "MacOSX" -> ranks := XString.Map.add "Darwin" 2 !ranks
    | _ -> () in

  !ranks

type machine_group =
  | Machine_group_default     (* e.g. i686 *)
  | Machine_group_64          (* e.g. x86_64 *)

(* All chosen machine-specific implementations must come from the same group.
   Unlisted archs are in Machine_group_default. *)
let get_machine_group = function
  | Some "x86_64" | Some "ppc64" -> Some Machine_group_64
  | Some "src" | None -> None
  | Some _ -> Some Machine_group_default

let get_machine_ranks ~multiarch machine =
  let ranks = ref @@ XString.Map.singleton machine 1 in

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
    | "armv7l" -> [| "armv6l" |]
    | "aarch64" when multiarch -> [|"armv7l"; "armv6l"|]
    | _ -> [||] in

  for i = 0 to Array.length compatible_machines - 1 do
    ranks := XString.Map.add compatible_machines.(i) (i + 2) !ranks
  done;

  !ranks

let os_ok ranking = function
  | None -> true
  | Some required -> XString.Map.mem required ranking
let machine_ok = os_ok

let os_rank ranks v = XString.Map.find_opt v ranks
let machine_rank = os_rank

let custom_os_ranking x = x
let custom_machine_ranking x = x

let format_machine_or_star = default "*"
let format_os_or_star = default "*"

let format_machine x = x
let format_os x = x

let is_src = function
  | Some "src" -> true
  | _ -> false

let platform system =
  let p = system#platform in
  (p.Platform.os, p.Platform.machine)

let linux = "Linux"
let x86_64 = "x86_64"
