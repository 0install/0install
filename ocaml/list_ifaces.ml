(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install list" command *)

open Options
open Support

let handle options flags args =
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  (* Actually, we list all the cached feeds. Close enough. *)
  let ifaces = Zeroinstall.Feed_cache.list_all_feeds options.config in
  let results =
    match args with
    | [] -> ifaces
    | [query] ->
        let re = Str.regexp_string_case_fold query in
        ifaces |> XString.Set.filter (fun item ->
          try Str.search_forward re item 0 |> ignore; true
          with Not_found -> false)
    | _ -> raise (Support.Argparse.Usage_error 1) in

  results |> XString.Set.iter (fun item -> Format.fprintf options.stdout "%s@." item)
