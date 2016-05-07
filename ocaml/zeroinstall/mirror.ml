(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Support functions for using mirror servers *)

open Support.Common
open General

module U = Support.Utils

let escape_slashes s = Str.global_replace U.re_slash "%23" s
let re_scheme_sep = Str.regexp_string "://"
let re_remote_feed = Str.regexp "^\\(https?\\)://\\([^/]*@\\)?\\([^/:]+\\)\\(:[^/]*\\)?/"

(* The algorithm from 0mirror. *)
let get_feed_dir (`Remote_feed feed) =
  if String.contains feed '#' then (
    raise_safe "Invalid URL '%s'" feed
  ) else (
    let scheme, rest = U.split_pair re_scheme_sep feed in
    if not (String.contains rest '/') then
      raise_safe "Missing / in %s" feed;
    let domain, rest = U.split_pair U.re_slash rest in
    [scheme; domain; rest] |> List.iter (fun part ->
      if part = "" || U.starts_with part "." then
        raise_safe "Invalid URL '%s'" feed
    );
    String.concat "/" ["feeds"; scheme; domain; escape_slashes rest]
  )

(* Don't bother trying the mirror for localhost URLs. *)
let can_try_mirror url =
  if Str.string_match re_remote_feed url 0 then (
    let scheme = Str.matched_group 1 url in
    let domain = Str.matched_group 3 url in
    match scheme with
    | "http" | "https" when domain <> "localhost" -> true
    | _ -> false
  ) else (
    log_warning "Failed to parse URL '%s'" url;
    false
  )

let get_mirror_url mirror feed_url resource =
  match feed_url with
  | `Local_feed _ | `Distribution_feed _ -> None
  | `Remote_feed url as feed_url ->
      if can_try_mirror url then
        Some (mirror ^ "/" ^ (get_feed_dir feed_url) ^ "/" ^ resource)
      else None

let for_impl config impl =
  config.mirror |> pipe_some (fun mirror ->
    let {Feed_url.feed; id} = Impl.get_id impl in
    get_mirror_url mirror feed ("impl/" ^ escape_slashes id)
    |> pipe_some (fun url -> Some (Recipe.get_mirror_download url))
  )

let for_archive config url =
  match config.mirror with
  | Some mirror when can_try_mirror url ->
      let escaped = Str.global_replace (Str.regexp_string "/") "#" url |> Curl.escape in
      Some (mirror ^ "/archive/" ^ escaped)
  | _ -> None

let for_feed config feed =
  config.mirror |> pipe_some (fun mirror -> get_mirror_url mirror feed "latest.xml")
