(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support

type t = {
  extra_restrictions : Impl.restriction XString.Map.t;  (* iface -> test *)
  os_ranks : Arch.os_ranking;
  machine_ranks : Arch.machine_ranking;
  languages : int Support.Locale.LangMap.t;
  allowed_uses : XString.Set.t;                         (* deprecated *)
  may_compile : bool;
}

let os_ok t v = Arch.os_ok t.os_ranks v
let machine_ok t ~want_source v =
  if Arch.is_src v then want_source
  else if want_source then false
  else Arch.machine_ok t.machine_ranks v

let lang_ok t (lang, _country) =
  Support.Locale.LangMap.mem (lang, None) t.languages

let use_ok t = function
  | Some use when not (XString.Set.mem use t.allowed_uses) -> false
  | _ -> true

let os_rank t os = Arch.os_rank t.os_ranks os

let machine_rank t machine = Arch.machine_rank t.machine_ranks machine

let lang_rank t lang =
  try Support.Locale.LangMap.find lang t.languages
  with Not_found -> 0

let user_restriction_for t iface = XString.Map.find_opt iface t.extra_restrictions

let use_feed t ~want_source feed =
  let machine_ok =
    match feed.Feed_import.machine with
    | None -> true    (* Feed doesn't say what it contains, so we can't safely skip it *)
    | m when Arch.is_src m -> want_source || t.may_compile (* Feed contains only source *)
    | Some _ when want_source -> false      (* Feed contains only binaries and we want source *)
    | Some _ as m -> Arch.machine_ok t.machine_ranks m in
  machine_ok && Arch.os_ok t.os_ranks feed.Feed_import.os
