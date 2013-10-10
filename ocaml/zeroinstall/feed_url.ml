(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
module U = Support.Utils

let parse_non_distro url =
  if U.path_is_absolute url then `local_feed url
  else if U.starts_with url "http://" || U.starts_with url "https://" then `remote_feed url
  else if U.starts_with url "distribution:" then raise_safe "Can't use a distribution feed here! ('%s')" url
  else raise_safe "Invalid feed URL '%s'" url

let parse url =
  if U.starts_with url "distribution:" then `distribution_feed (U.string_tail url 13 |> parse_non_distro)
  else parse_non_distro url

let rec format_url = function
  | `distribution_feed master -> "distribution:" ^ (format_url master)
  | `local_feed path -> path
  | `remote_feed url -> url

