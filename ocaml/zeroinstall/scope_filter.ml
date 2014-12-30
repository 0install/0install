(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common

type t = {
  extra_restrictions : Impl.restriction StringMap.t;  (* iface -> test *)
  os_ranks : int StringMap.t;
  machine_ranks : int StringMap.t;
  languages : int Support.Locale.LangMap.t;
  allowed_uses : StringSet.t;                         (* deprecated *)
}

let os_ok t = function
  | None -> true
  | Some required_os -> StringMap.mem required_os t.os_ranks

let machine_ok t = function
  | None -> true
  | Some required_machine -> StringMap.mem required_machine t.machine_ranks

let lang_ok t (lang, _country) =
  Support.Locale.LangMap.mem (lang, None) t.languages

let use_ok t = function
  | Some use when not (StringSet.mem use t.allowed_uses) -> false
  | _ -> true

let os_rank t os = StringMap.find os t.os_ranks

let machine_rank t machine = StringMap.find machine t.machine_ranks

let lang_rank t lang =
  try Support.Locale.LangMap.find lang t.languages
  with Not_found -> 0

let user_restriction_for t iface = StringMap.find iface t.extra_restrictions
