(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install search" command *)

open Options
open Zeroinstall.General
open Support
open Support.Common

module Q = Support.Qdom
module U = Support.Utils
module Msg = Support.Qdom.Empty

let handle options flags args =
  let config = options.config in
  let tools = options.tools in
  options.tools#set_use_gui `No;   (* There's no GUI for searches; using it just disabled the progress indicator. *)
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  if args = [] then raise (Support.Argparse.Usage_error 1);

  match config.mirror with
  | None -> Safe_exn.failf "No mirror configured; search is unavailable"
  | Some mirror ->
      let url = mirror ^ "/search/?q=" ^ Zeroinstall.Http.escape (String.concat " " args) in
      log_info "Fetching %s..." url;
      Lwt_main.run begin
        U.with_switch @@ fun switch ->
        let downloader = tools#download_pool#with_monitor tools#ui#watcher#monitor in
        Zeroinstall.Downloader.download downloader ~switch url >>= function
        | `Aborted_by_user -> Lwt.return ()
        | `Network_failure msg -> Safe_exn.failf "%s" msg
        | `Tmpfile path ->
            let results = U.read_file config.system path in
            Lwt_switch.turn_off switch >>= fun () ->
            let root = `String (0, results) |> Xmlm.make_input |> Q.parse_input (Some url) in

            Msg.check_tag "results" root;

            let print fmt = Format.fprintf options.stdout (fmt ^^ "@.") in

            let first = ref true in
            root |> Msg.iter ~name:"result" (fun child ->
                    if !first then first := false
                    else print "";

                    print "%s" (Msg.get_attribute "uri" child);
                    let score = Msg.get_attribute "score" child in

                    let summary = ref "" in
                    child |> Msg.iter ~name:"summary" (fun elem ->
                      summary := elem.Q.last_text_inside
                    );
                    print "  %s - %s [%s%%]" (Msg.get_attribute "name" child) !summary score
            );
            Lwt.return ()
      end
