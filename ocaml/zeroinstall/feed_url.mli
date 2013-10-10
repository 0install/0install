(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Feed URLs *)

type non_distro_feed = [`local_feed of Support.Common.filepath | `remote_feed of string]

val parse_non_distro : General.feed_url -> non_distro_feed

val parse : General.feed_url -> [`distribution_feed of non_distro_feed | non_distro_feed ]

val format_url : [< `distribution_feed of non_distro_feed | non_distro_feed] -> General.feed_url
