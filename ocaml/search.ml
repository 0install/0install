(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install search" command *)

open Options
open Zeroinstall.General
open Support.Common

module Q = Support.Qdom
module U = Support.Utils

let handle options flags args =
  let config = options.config in
  let tools = options.tools in
  options.tools#set_use_gui `No;   (* There's no GUI for searches; using it just disabled the progress indicator. *)
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  if args = [] then raise (Support.Argparse.Usage_error 1);

  match config.mirror with
  | None -> raise_safe "No mirror configured; search is unavailable"
  | Some mirror ->
      let url = mirror ^ "/search/?q=" ^ Curl.escape (String.concat " " args) in
      log_info "Fetching %s..." url;
      let switch = Lwt_switch.create () in
      try
        let downloader = tools#download_pool#with_monitor tools#ui#watcher#monitor in
        let result = Zeroinstall.Downloader.download downloader ~switch url in
        match Lwt_main.run result with
        | `Aborted_by_user -> ()
        | `Network_failure msg -> raise_safe "%s" msg
        | `Tmpfile path ->
            let results = U.read_file config.system path in
            Lwt_main.run (Lwt_switch.turn_off switch);
            let root = `String (0, results) |> Xmlm.make_input |> Q.parse_input (Some url) in

            Empty.check_tag "results" root;

            let print fmt = Support.Utils.print config.system fmt in

            let first = ref true in
            root |> Empty.iter ~name:"result" (fun child ->
                    if !first then first := false
                    else print "";

                    print "%s" (Empty.get_attribute "uri" child);
                    let score = Empty.get_attribute "score" child in

                    let summary = ref "" in
                    child |> Empty.iter ~name:"summary" (fun elem ->
                      summary := elem.Q.last_text_inside
                    );
                    print "  %s - %s [%s%%]" (Empty.get_attribute "name" child) !summary score
            );
      with ex ->
        Lwt_main.run (Lwt_switch.turn_off switch);
        raise ex
