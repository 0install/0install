(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
module U = Support.Utils

type local_feed = [`Local_feed of Support.Common.filepath]
type remote_feed = [`Remote_feed of string]
type non_distro_feed = [local_feed | remote_feed]
type parsed_feed_url = [`Distribution_feed of non_distro_feed | non_distro_feed]

let is_http url = XString.starts_with url "http://"
let is_https url = XString.starts_with url "https://"
let is_distro url = XString.starts_with url "distribution:"

let parse_non_distro url =
  if U.path_is_absolute url then `Local_feed url
  else if is_http url || is_https url then `Remote_feed url
  else if is_distro url then Safe_exn.failf "Can't use a distribution feed here! ('%s')" url
  else Safe_exn.failf "Invalid feed URL '%s'" url

let parse url =
  if is_distro url then `Distribution_feed (XString.tail url 13 |> parse_non_distro)
  else parse_non_distro url

let format_non_distro : non_distro_feed -> string = function
  | `Local_feed path -> path
  | `Remote_feed url -> url

let format_url = function
  | `Distribution_feed master -> "distribution:" ^ (format_non_distro master)
  | #non_distro_feed as x -> format_non_distro x

let pp f x = Format.pp_print_string f (format_url x)

let master_feed_of_iface uri = parse_non_distro uri

module FeedElt =
  struct
    type t = non_distro_feed
    let compare = compare
  end

module FeedSet = Set.Make(FeedElt)
module FeedMap = Map.Make(FeedElt)

(** A globally-unique identifier for an implementation. *)
type global_id = {
  feed : parsed_feed_url;
  id : string;
}
