(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install remove-feed" command *)

open Options
open Zeroinstall.General
open Support.Common

module G = Generic_select
module FC = Zeroinstall.Feed_cache

let handle options flags args =
  let config = options.config in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  match args with
  | [feed_url] ->
      let print fmt = Support.Utils.print config.system fmt in
      print "Feed '%s':" feed_url;
      let user_import = G.canonical_iface_uri config.system feed_url |> Zeroinstall.Feed_url.parse_non_distro in
      Add_feed.edit_feeds_interactive config `remove user_import
  | [iface; feed_src] ->
      let iface = G.canonical_iface_uri config.system iface in
      let feed_src = G.canonical_iface_uri config.system feed_src in
      let user_import = Zeroinstall.Feed_url.parse_non_distro feed_src |> Zeroinstall.Feed.make_user_import in

      let iface_config = FC.load_iface_config config iface in
      if not (List.mem user_import iface_config.FC.extra_feeds) then (
        raise_safe "Interface %s has no feed %s" iface feed_src
      );

      let extra_feeds = List.filter ((<>) user_import) iface_config.FC.extra_feeds in
      FC.save_iface_config config iface {iface_config with FC.extra_feeds}
  | _ -> raise (Support.Argparse.Usage_error 1)
