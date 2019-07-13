(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
open Support.Common

module U = Support.Utils
module Q = Support.Qdom
module G = Support.Gpg
module KI = Support.Qdom.Empty   (* Key info XML documents don't have a namespace. *)

type t = {
  config : General.config;
  cache : (G.fingerprint, Progress.key_vote list Lwt.t) Hashtbl.t
}

let lookup t fingerprint = Hashtbl.find_opt t.cache fingerprint

let make config = {config; cache = Hashtbl.create 10}

let parse_key_info xml =
  xml |> KI.check_tag "key-lookup";
  xml |> KI.map ~name:"item" (fun child ->
    let msg = child.Q.last_text_inside in
    if KI.get_attribute_opt "vote" child = Some "good" then
      (Progress.Good, msg)
    else
      (Progress.Bad, msg)
  )

let fetch_key t ~download fingerprint =
  match t.config.key_info_server with
  | None -> Lwt.return []
  | Some key_info_server ->
      if t.config.dry_run then (
        Dry_run.log "asking %s about key %s" key_info_server fingerprint;
      );
      let key_info_url = key_info_server ^ "/key/" ^ fingerprint in
      U.with_switch (fun switch ->
        download ~switch key_info_url >|= function
        | `Network_failure msg ->
            log_info "Error fetching key info: %s" msg;
            [Progress.Bad, "Error fetching key info: " ^ msg]
        | `Aborted_by_user ->
            [Progress.Bad, "Key lookup aborted by user"]
        | `Tmpfile tmpfile ->
            Q.parse_file t.config.system ~name:key_info_url tmpfile
            |> parse_key_info
      )

let get_exn t ~download fingerprint =
  let fetch () =
    let result = fetch_key t ~download fingerprint in
    Hashtbl.replace t.cache fingerprint result;
    result in
  match lookup t fingerprint with
  | None -> fetch ()
  | Some th ->
    let open Lwt in
    match state th with
    | Return _ | Sleep -> th
    | Fail _ -> fetch ()

let get t ~download fingerprint =
  Lwt.catch
    (fun () -> get_exn t ~download fingerprint)
    (fun ex ->
       log_warning ~ex "Error fetching key info";
       Lwt.return [Progress.Bad, "Error fetching key info: " ^ (Printexc.to_string ex)]
    )
