(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install add-feed" command *)

open Options
open Zeroinstall
open Zeroinstall.General
open Support.Common

module F = Zeroinstall.Feed
module G = Generic_select
module FC = Zeroinstall.Feed_cache

let edit_feeds config iface mode new_import =
  let print fmt = Support.Utils.print config.system fmt in
  let iface_config = FC.load_iface_config config iface in
  let extra_feeds =
    match mode with
    | `Add -> new_import :: iface_config.FC.extra_feeds
    | `Remove -> List.filter ((<>) new_import) iface_config.FC.extra_feeds in

  FC.save_iface_config config iface {iface_config with FC.extra_feeds};
  print "";
  print "Feed list for interface '%s' is now:" iface;
  if extra_feeds <> [] then
    extra_feeds |> List.iter (fun feed -> print "- %s" (Zeroinstall.Feed_url.format_url feed.F.feed_src))
  else
    print "(no feeds)"

let edit_feeds_interactive config (mode:[`Add | `Remove]) feed_url =
  let (`Remote_feed url | `Local_feed url) = feed_url in
  let print fmt = Support.Utils.print config.system fmt in
  let feed = FC.get_cached_feed config feed_url |? lazy (failwith "Feed still not cached!") in
  let new_import = F.make_user_import feed_url in
  match F.get_feed_targets feed with
  | [] -> Element.raise_elem "Missing <feed-for> element; feed can't be used as a feed for any other interface." feed.F.root
  | candidate_interfaces ->
      (* Display the options to the user *)
      let i = ref 0 in
      let interfaces = ref [] in
      candidate_interfaces |> List.iter (fun iface ->
        let iface_config = FC.load_iface_config config iface in
        incr i;

        match List.mem new_import iface_config.FC.extra_feeds, mode with
        | true, `Remove ->
            print "%d) Remove as feed for '%s'" !i iface;
            interfaces := iface :: !interfaces
        | false, `Add ->
            print "%d) Add as feed for '%s'" !i iface;
            interfaces := iface :: !interfaces
        | _ -> ()
      );

      if !interfaces = [] then (
        match mode with
        | `Remove -> raise_safe "%s is not registered as a feed for %s" url (List.hd candidate_interfaces)
        | `Add -> raise_safe "%s already registered as a feed for %s" url (List.hd candidate_interfaces)
      );

      print "";
      while true do
        config.system#print_string "Enter a number, or CTRL-C to cancel [1]: ";
        flush stdout;
        let choice = input_line stdin in
        let i =
          if choice = "" then 1
          else (
            try int_of_string choice
            with Failure _ -> 0
          ) in

        if i > 0 && i <= List.length !interfaces then (
          edit_feeds config (List.nth !interfaces (i - 1)) mode new_import;
          raise (System_exit 0)
        );
        print "Invalid number. Try again. (1 to %d)" (List.length !interfaces)
      done

let handle options flags args =
  let config = options.config in
  let tools = options.tools in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  match args with
  | [new_feed] ->
      let print fmt = Support.Utils.print config.system fmt in
      print "Feed '%s':" new_feed;
      let new_feed = G.canonical_feed_url config.system new_feed in

      (* If the feed is remote and missing, download it. *)
      let feed =
        match new_feed with
        | `Remote_feed _ as feed ->
            let missing = FC.get_cached_feed config feed = None in
            if missing || (config.network_use <> Offline && FC.is_stale config feed) then (
              print "Downloading feed; please wait...";
              flush stdout;
              try
                let fetcher = tools#make_fetcher tools#ui#watcher in
                match Zeroinstall.Driver.download_and_import_feed fetcher feed |> Lwt_main.run with
                | `Success _ -> print "Done"
                | `Aborted_by_user -> raise (System_exit 1)
                | `No_update ->
                    if missing then raise_safe "Failed to download missing feed"  (* Shouldn't happen *)
                    else print "No update"
              with Safe_exception (msg, _) when not missing ->
                log_warning "Update failed: %s" msg
            );
            feed
        | `Local_feed path as feed ->
            if not (config.system#file_exists path) then
              raise_safe "Local feed file '%s' does not exist" path;
            feed in

      edit_feeds_interactive config `Add feed
  | [iface; feed_src] ->
      let iface = G.canonical_iface_uri config.system iface in
      let feed_src = G.canonical_feed_url config.system feed_src in
      let new_import = F.make_user_import feed_src in

      let iface_config = FC.load_iface_config config iface in
      if List.mem new_import iface_config.FC.extra_feeds then (
        raise_safe "Interface %s already has a feed %s" iface (Zeroinstall.Feed_url.format_url feed_src)
      );

      let extra_feeds = new_import :: iface_config.FC.extra_feeds in
      FC.save_iface_config config iface {iface_config with FC.extra_feeds}
  | _ -> raise (Support.Argparse.Usage_error 1)
