(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install slave" command *)

open Options
open Zeroinstall.General
open Support.Common

module Q = Support.Qdom
module J = Yojson.Basic
module JC = Zeroinstall.Json_connection
module H = Zeroinstall.Helpers
module Ui = Zeroinstall.Ui

let make_no_gui (connection:JC.json_connection) : Ui.ui_handler =
  let json_of_votes =
    List.map (function
      | Ui.Good, msg -> `List [`String "good"; `String msg]
      | Ui.Bad, msg -> `List [`String "bad"; `String msg]
    ) in

  object
    method start_monitoring ~cancel:_ ~url:_ ~progress:_ ?hint:_  ~id:_ = Lwt.return ()
    method stop_monitoring _id = Lwt.return ()

    method confirm_keys feed_url infos =
      let pending_tasks = ref [] in

      let handle_pending fingerprint votes =
        let task =
          lwt votes = votes in
          connection#invoke "update-key-info" [`String fingerprint; `List (json_of_votes votes)] in
        pending_tasks := task :: !pending_tasks in

      try_lwt
        let json_infos = infos |> List.map (fun (fingerprint, votes) ->
          let json_votes =
            match Lwt.state votes with
            | Lwt.Sleep -> handle_pending fingerprint votes; [`String "pending"]
            | Lwt.Fail ex -> [`List [`String "bad"; `String (Printexc.to_string ex)]]
            | Lwt.Return votes -> json_of_votes votes in
          (fingerprint, `List json_votes)
        ) in
        match_lwt connection#invoke "confirm-keys" [`String (Zeroinstall.Feed_url.format_url feed_url); `Assoc json_infos] with
        | `List confirmed_keys -> confirmed_keys |> List.map Yojson.Basic.Util.to_string |> Lwt.return
        | _ -> raise_safe "Invalid response"
      finally
        !pending_tasks |> List.iter Lwt.cancel;
        Lwt.return ()

    method confirm message =
      match_lwt connection#invoke "confirm" [`String message] with
      | `String "ok" -> Lwt.return `ok
      | `String "cancel" -> Lwt.return `cancel
      | json -> raise_safe "Invalid response '%s'" (J.to_string json)

    method use_gui = None
  end

let make_ui config connection (slave:Zeroinstall.Python.slave) use_gui : Ui.ui_handler Lazy.t = lazy (
  let use_gui =
    match use_gui, config.dry_run with
    | Yes, true -> raise_safe "Can't use GUI with --dry-run"
    | (Maybe|No), true -> No
    | use_gui, false -> use_gui in

  match use_gui with
  | No -> make_no_gui connection
  | Yes | Maybe ->
      if Ui.check_gui config.system slave use_gui then new Ui.gui_ui slave
      else make_no_gui connection
)

let handle options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  if args <> [] then raise (Support.Argparse.Usage_error 1);

  let config = options.config in

  let connection = new JC.json_connection ~from_peer:Lwt_io.stdin ~to_peer:Lwt_io.stdout in

  let driver = lazy (
    let slave = new Zeroinstall.Python.slave config in
    let distro = Zeroinstall.Distro_impls.get_host_distribution config in
    let trust_db = new Zeroinstall.Trust.trust_db config in
    let ui = make_ui config connection slave options.gui in
    let downloader = new Zeroinstall.Downloader.downloader ui  ~max_downloads_per_site:2 in
    let fetcher = new Zeroinstall.Fetch.fetcher config trust_db downloader distro ui in
    new Zeroinstall.Driver.driver config fetcher distro ui
  ) in

  let do_select = function
    | [reqs; `Bool refresh] ->
        let requirements = reqs |> J.Util.member "interface" |> J.Util.to_string |> Zeroinstall.Requirements.default_requirements in
        let driver = Lazy.force driver in
        lwt resp =
          try_lwt
            match_lwt H.solve_and_download_impls driver requirements `Select_only ~refresh with
            | None -> Lwt.return [`String "aborted-by-user"]
            | Some sels -> Lwt.return [`String "ok"; `String (Q.to_utf8 sels)]
          with Safe_exception (msg, _) -> Lwt.return [`String "fail"; `String msg] in
        `List resp |> Lwt.return
    | _ -> raise JC.Bad_request in

  connection#register_handler "select" do_select;

  let module V = Zeroinstall.Versions in
  let agreed_version = connection#invoke "select-api-version" [`String Zeroinstall.About.version]
  |> Lwt_main.run |> J.Util.to_string |> V.parse_version in

  if agreed_version < V.parse_version "2.5" then
    raise_safe "Minimum supported API version is 2.5"
  else if agreed_version > Zeroinstall.About.parsed_version then
    raise_safe "Maximum supported API version is %s" Zeroinstall.About.version;

  Lwt_main.run connection#run;
  log_info "OCaml slave exiting"
