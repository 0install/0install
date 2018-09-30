(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install import" command *)

open Options
open Zeroinstall.General
open Support
open Support.Common

module Q = Support.Qdom
module FeedAttr = Zeroinstall.Constants.FeedAttr
module U = Support.Utils

let import_feed options arg =
  let tools = options.tools in
  let system = options.config.system in

  if not (system#file_exists arg) then
    Safe_exn.failf "File '%s' does not exist" arg;

  log_info "Importing from file '%s'" arg;
  let xml = U.read_file system arg in
  let root = `String (0, xml) |> Xmlm.make_input |> Q.parse_input (Some arg) in
  let url = ZI.get_attribute FeedAttr.uri root in
  let parsed_url = match Zeroinstall.Feed_url.parse_non_distro url with
    | `Remote_feed _ as url -> url
    | `Local_feed _ -> Safe_exn.failf "Invalid URI '%s' on feed" url in

  log_info "Importing feed %s" url;

  Lwt_main.run ((tools#make_fetcher tools#ui#watcher)#import_feed parsed_url xml)

let handle options flags args =
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  if args = [] then raise (Support.Argparse.Usage_error 1);
  args |> List.iter (import_feed options)
