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
    method monitor _dl = ()
    method impl_added_to_store = ()

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
  end

let make_ui config connection use_gui : Zeroinstall.Gui.ui_type Lazy.t = lazy (
  let use_gui =
    match use_gui, config.dry_run with
    | Yes, true -> raise_safe "Can't use GUI with --dry-run"
    | (Maybe|No), true -> No
    | use_gui, false -> use_gui in

  match use_gui with
  | No -> Zeroinstall.Gui.Ui (make_no_gui connection)
  | Yes | Maybe ->
      match Zeroinstall.Gui.try_get_gui config ~use_gui with
      | Some gui -> Zeroinstall.Gui.Gui gui
      | None -> Zeroinstall.Gui.Ui (make_no_gui connection)
)

let parse_restrictions = function
  | `Null -> StringMap.empty
  | `Assoc items ->
      items |> List.fold_left (fun map (iface, expr) ->
        StringMap.add iface (J.Util.to_string expr) map
      ) StringMap.empty
  | json -> raise (J.Util.Type_error ("Not a map", json))

let parse_requirements json_assoc =
  let table = Hashtbl.create (List.length json_assoc) in
  json_assoc |> List.iter (fun (name, value) -> Hashtbl.add table name value);
  let pop name =
    try
      let value = Hashtbl.find table name in
      Hashtbl.remove table name;
      value
    with Not_found -> `Null in

  let reqs =
    Zeroinstall.Requirements.({
      interface_uri = pop "interface" |> J.Util.to_string;
      command = pop "command" |> J.Util.to_string_option;
      source = pop "source" |> J.Util.to_bool_option |> default false;
      extra_restrictions = pop "extra_restrictions" |> parse_restrictions;
      os = pop "os" |> J.Util.to_string_option;
      cpu = pop "cpu" |> J.Util.to_string_option;
      message = pop "message" |> J.Util.to_string_option;
  }) in
  table |> Hashtbl.iter (fun name _ -> log_warning "Unexpected requirements field '%s'!" name);
  reqs

let register_handlers config gui connection =
  let gui = make_ui config connection gui in

  let fetcher = lazy (
    let ui = lazy (
      match Lazy.force gui with
      | Zeroinstall.Gui.Gui gui -> (gui :> Ui.ui_handler)
      | Zeroinstall.Gui.Ui ui -> ui
    ) in
    let distro = Zeroinstall.Distro_impls.get_host_distribution config in
    let trust_db = new Zeroinstall.Trust.trust_db config in
    let downloader = new Zeroinstall.Downloader.downloader ~max_downloads_per_site:2 in
    new Zeroinstall.Fetch.fetcher config trust_db distro downloader ui
  ) in

  let do_select = function
    | [`Assoc reqs; `Bool refresh] ->
        let requirements = parse_requirements reqs in
        let fetcher = Lazy.force fetcher in
        lwt resp =
          try_lwt
            match_lwt H.solve_and_download_impls (Lazy.force gui) fetcher requirements `Select_only ~refresh with
            | None -> `List [`String "aborted-by-user"] |> Lwt.return
            | Some sels -> `WithXML (`List [`String "ok"], sels) |> Lwt.return
          with Safe_exception (msg, _) -> `List [`String "fail"; `String msg] |> Lwt.return in
        resp |> Lwt.return
    | _ -> raise JC.Bad_request in

  connection#register_handler "select" do_select

let handle options flags args =
  let config = options.config in
  Support.Argparse.iter_options flags (Common_options.process_common_option options);

  match args with
  | [requested_api_version] ->
      let module V = Zeroinstall.Versions in
      let requested_api_version = V.parse_version requested_api_version in
      if requested_api_version < V.parse_version "2.6" then
        raise_safe "Minimum supported API version is 2.6";
      let api_version = min requested_api_version Zeroinstall.About.parsed_version in

      let connection = new JC.json_connection ~from_peer:Lwt_io.stdin ~to_peer:Lwt_io.stdout in
      register_handlers config options.gui connection;
      connection#notify "set-api-version" [`String (V.format_version api_version)] |> Lwt_main.run;

      Lwt_main.run connection#run;
      log_info "OCaml slave exiting"
  | _ -> raise (Support.Argparse.Usage_error 1);
