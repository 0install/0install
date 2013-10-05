(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Common

module U = Utils

let rec norm_url_path base rel =
  match base, rel with
  | base, [] -> base
  | base, "" :: rel -> norm_url_path base rel
  | base, "." :: rel -> norm_url_path base rel
  | _ :: base, ".." :: rel -> norm_url_path base rel
  | base, next :: rel -> norm_url_path (next :: base) rel

(* foo?bar -> ("foo", "?bar") *)
let split_query path =
  try
    let i = String.index path '?' in
    (String.sub path 0 i, U.string_tail path i)
  with Not_found -> (path, "")

let join_url base rel =
  if List.exists (U.starts_with rel) ["http://"; "https://"; "ftp://"] then (
    (* rel is absolute *)
    rel     
  ) else if U.starts_with rel "//" then (
    (* https://example.com + //dl.example.com/foo -> https://dl.example.com/foo *)
    let i = String.index base ':' in
    String.sub base 0 (i + 1) ^ rel
  ) else (
    let re_url = Str.regexp "\\([a-zA-Z]+://[^/]*\\)\\(/.*\\)?" in
    if Str.string_match re_url base 0 then (
      let base_netloc = Str.matched_group 1 base in
      let base_path =
        try Str.matched_group 2 base
        with Not_found -> "/" in
      if U.starts_with rel "/" then (
        (* http://example.com/* + /foo -> http://example.com/foo *)
        base_netloc ^ rel
      ) else (
        (* Split off query strings (?...) *)
        let base_path, _base_query = split_query base_path in
        let rel_path, rel_query = split_query rel in

        (* Base dir/path.xml -> dir *)
        let last_base_slash = String.rindex base_path '/' in
        let base_path =
          if last_base_slash < 2 then ""
          else String.sub base_path 1 (last_base_slash - 1) in

        (* Join paths *)
        let base_parts = Str.split_delim U.re_slash base_path in 
        let rel_parts = Str.split_delim U.re_slash rel_path in 
        let norm_path = rel_parts |> norm_url_path (List.rev base_parts) in

        (* Reattach query *)
        base_netloc ^ "/" ^ String.concat "/" (List.rev norm_path) ^ rel_query
      )
    ) else (
      raise_safe "Invalid base URL '%s'" base
    )
  )
