(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install list-feeds" command *)

open Options
open Zeroinstall.General

module F = Zeroinstall.Feed
module FC = Zeroinstall.Feed_cache

let handle options flags args =
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  match args with
  | [iface] ->
      let iface = Generic_select.canonical_iface_uri options.config.system iface in
      let iface_config = FC.load_iface_config options.config iface in
      begin match iface_config.FC.extra_feeds with
      | [] -> Format.fprintf options.stdout "(no feeds)@."
      | extra_feeds ->
          extra_feeds |> List.iter (fun {Zeroinstall.Feed_import.src; _} ->
            Format.fprintf options.stdout "%s@." (Zeroinstall.Feed_url.format_url src);
          )
      end
  | _ -> raise (Support.Argparse.Usage_error 1)
