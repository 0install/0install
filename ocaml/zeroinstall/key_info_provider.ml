(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
open Support.Common

module U = Support.Utils
module Q = Support.Qdom
module G = Support.Gpg
module KI = Empty   (* Key info XML documents don't have a namespace. *)

type t = (General.config * (G.fingerprint, Progress.key_vote list Lwt.t) Hashtbl.t)

let make config = (config, Hashtbl.create 10)

let parse_key_info xml =
  xml |> KI.check_tag "key-lookup";
  xml |> KI.map ~name:"item" (fun child ->
    let msg = child.Q.last_text_inside in
    if KI.get_attribute_opt "vote" child = Some "good" then
      (Progress.Good, msg)
    else
      (Progress.Bad, msg)
  )

let get (config, cache) ~download fingerprint =
  try Hashtbl.find cache fingerprint
  with Not_found ->
    let result =
      try_lwt
        match config.key_info_server with
        | None -> Lwt.return []
        | Some key_info_server ->
            if config.dry_run then (
              Dry_run.log "asking %s about key %s" key_info_server fingerprint;
            );
            let key_info_url = key_info_server ^ "/key/" ^ fingerprint in
            U.with_switch (fun switch ->
              download ~switch key_info_url >|= function
              | `network_failure msg ->
                  Hashtbl.remove cache fingerprint;
                  log_info "Error fetching key info: %s" msg;
                  [Progress.Bad, "Error fetching key info: " ^ msg]
              | `aborted_by_user ->
                  Hashtbl.remove cache fingerprint;
                  [Progress.Bad, "Key lookup aborted by user"]
              | `tmpfile tmpfile ->
                  Q.parse_file config.system ~name:key_info_url tmpfile
                  |> parse_key_info
            )
      with ex ->
        log_warning ~ex "Error fetching key info";
        Hashtbl.remove cache fingerprint;
        Lwt.return [Progress.Bad, "Error fetching key info: " ^ (Printexc.to_string ex)] in

    (* Add the pending result immediately.
     * If the lookup fails, we'll remove it later. *)
    Hashtbl.add cache fingerprint result;
    result
