(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Feed URLs *)

val parse_non_distro :
  General.feed_url -> [> `local_feed of Support.Common.filepath | `remote_feed of string ]

val parse :
  General.feed_url ->
  [> `distribution_feed of
       [> `local_feed of Support.Common.filepath | `remote_feed of string ]
   | `local_feed of Support.Common.filepath
   | `remote_feed of string ]

val format_url :
  ([< `distribution_feed of 'a
    | `local_feed of Support.Common.filepath
    | `remote_feed of string ]
   as 'a) ->
  General.feed_url
