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
module Ui = Zeroinstall.Ui
module Progress = Zeroinstall.Progress

let make_no_gui (connection:JC.json_connection) : Ui.ui_handler =
  let json_of_votes =
    List.map (function
      | Progress.Good, msg -> `List [`String "good"; `String msg]
      | Progress.Bad, msg -> `List [`String "bad"; `String msg]
    ) in

  let ui =
    (* There's more stuff we could expose to clients easily; see Zeroinstall.Progress.watcher for a list of things
     * that could be overridden. *)
    object
      inherit Zeroinstall.Console.batch_ui

      method! confirm_keys feed_url infos =
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

      method! confirm message =
        match_lwt connection#invoke "confirm" [`String message] with
        | `String "ok" -> Lwt.return `ok
        | `String "cancel" -> Lwt.return `cancel
        | json -> raise_safe "Invalid response '%s'" (J.to_string json)
    end in

  (ui :> Zeroinstall.Ui.ui_handler)

let make_ui config connection use_gui : Zeroinstall.Ui.ui_handler =
  let use_gui =
    match use_gui, config.dry_run with
    | Yes, true -> raise_safe "Can't use GUI with --dry-run"
    | (Maybe|No), true -> No
    | use_gui, false -> use_gui in

  match use_gui with
  | No -> make_no_gui connection
  | Yes | Maybe ->
      match Zeroinstall.Gui.try_get_gui config ~use_gui with
      | Some gui -> gui
      | None -> make_no_gui connection

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
      autocompile = pop "compile" |> J.Util.to_bool_option;
  }) in
  table |> Hashtbl.iter (fun name _ -> log_warning "Unexpected requirements field '%s'!" name);
  reqs

let select options (ui:Zeroinstall.Ui.ui_handler) requirements refresh =
  let success ~sels ~stale =
    let info = `Assoc [
      "stale", `Bool stale;
    ] in
    let json : JC.J.json = `List [`String "ok"; info] in
    `WithXML (json, Zeroinstall.Selections.as_xml sels) |> Lwt.return in

  let select_with_refresh refresh =
    match_lwt ui#run_solver options.tools `Select_only requirements ~refresh with
    | `Success sels -> success ~sels ~stale:false
    | `Aborted_by_user -> `List [`String "aborted-by-user"] |> Lwt.return in

  if refresh || options.tools#use_gui = Yes then select_with_refresh refresh
  else (
    let feed_provider = new Zeroinstall.Feed_provider_impl.feed_provider options.config options.tools#distro in
    match Zeroinstall.Solver.solve_for options.config feed_provider requirements with
    | (false, _results) ->
        log_info "Quick solve failed; can't select without updating feeds";
        select_with_refresh true
    | (true, results) ->
        let sels = results#get_selections in
        success ~sels ~stale:feed_provider#have_stale_feeds
  )

(* Note: this function only supports the latest API. Previous APIs are handled using wrappers. *)
let handle_request options ui = function
  | "select", [`Assoc reqs; `Bool refresh] -> begin
      let requirements = parse_requirements reqs in
      try_lwt select options ui requirements refresh
      with Safe_exception (msg, _) -> `List [`String "fail"; `String msg] |> Lwt.return end
  | _ -> raise JC.Bad_request

(* Wrap for 2.6. Convert 2.6 requests and responses to/from 2.7 format. *)
let wrap_for_2_6 next (op, args) =
  match op with
  | "select" ->
      (* Strip out the new "status" response for old clients *)
      begin match_lwt next (op, args) with
      | `WithXML (`List [`String "ok"; _info], xml) -> `WithXML (`List [`String "ok"], xml) |> Lwt.return
      | x -> Lwt.return x end;
  | _ -> next (op, args)

let handle options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);

  match args with
  | [requested_api_version] ->
      let module V = Zeroinstall.Versions in
      let requested_api_version = V.parse_version requested_api_version in
      if requested_api_version < V.parse_version "2.6" then
        raise_safe "Minimum supported API version is 2.6";
      let api_version = min requested_api_version Zeroinstall.About.parsed_version in

      let handler, set_handler = Lwt.wait () in
      let connection = new JC.json_connection ~from_peer:Lwt_io.stdin ~to_peer:Lwt_io.stdout handler in
      let ui = make_ui options.config connection options.tools#use_gui in

      let handle_request = handle_request options ui in
      let handle_request =
        if api_version <= V.parse_version "2.6" then wrap_for_2_6 handle_request
        else handle_request in

      Lwt.wakeup set_handler handle_request;

      connection#notify "set-api-version" [`String (V.format_version api_version)] |> Lwt_main.run;

      Lwt_main.run connection#run;
      log_info "OCaml slave exiting"
  | _ -> raise (Support.Argparse.Usage_error 1);
