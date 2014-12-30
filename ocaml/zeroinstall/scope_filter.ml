(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common

type t = {
  extra_restrictions : Impl.restriction StringMap.t;  (* iface -> test *)
  os_ranks : Arch.os_ranking;
  machine_ranks : Arch.machine_ranking;
  languages : int Support.Locale.LangMap.t;
  allowed_uses : StringSet.t;                         (* deprecated *)
}

let os_ok t v = Arch.os_ok t.os_ranks v
let machine_ok t v = Arch.machine_ok t.machine_ranks v

let lang_ok t (lang, _country) =
  Support.Locale.LangMap.mem (lang, None) t.languages

let use_ok t = function
  | Some use when not (StringSet.mem use t.allowed_uses) -> false
  | _ -> true

let os_rank t os = Arch.os_rank t.os_ranks os

let machine_rank t machine = Arch.machine_rank t.machine_ranks machine

let lang_rank t lang =
  try Support.Locale.LangMap.find lang t.languages
  with Not_found -> 0

let user_restriction_for t iface = StringMap.find iface t.extra_restrictions
