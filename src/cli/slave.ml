(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install slave" command *)

open Options
open Zeroinstall.General
open Support
open Support.Common
open Zeroinstall

module J = Yojson.Basic
module JC = Zeroinstall.Json_connection
module Ui = Zeroinstall.Ui
module Progress = Zeroinstall.Progress

let make_no_gui connection : Ui.ui_handler =
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
            votes >>= fun votes ->
            JC.invoke connection "update-key-info" [`String fingerprint; `List (json_of_votes votes)] in
          pending_tasks := task :: !pending_tasks in

        Lwt.finalize
          (fun () ->
            let json_infos = infos |> List.map (fun (fingerprint, votes) ->
              let json_votes =
                match Lwt.state votes with
                | Lwt.Sleep -> handle_pending fingerprint votes; [`String "pending"]
                | Lwt.Fail ex -> [`List [`String "bad"; `String (Printexc.to_string ex)]]
                | Lwt.Return votes -> json_of_votes votes in
              (fingerprint, `List json_votes)
            ) in
            JC.invoke connection "confirm-keys" [`String (Zeroinstall.Feed_url.format_url feed_url); `Assoc json_infos] >>= function
            | `List confirmed_keys -> confirmed_keys |> List.map Yojson.Basic.Util.to_string |> Lwt.return
            | _ -> Safe_exn.failf "Invalid response"
          )
          (fun () ->
            !pending_tasks |> List.iter Lwt.cancel;
            Lwt.return ()
          )

      method! confirm message =
        JC.invoke connection "confirm" [`String message] >>= function
        | `String "ok" -> Lwt.return `Ok
        | `String "cancel" -> Lwt.return `Cancel
        | json -> Safe_exn.failf "Invalid response '%a'" JC.pp_opt_xml json
    end in

  (ui :> Zeroinstall.Ui.ui_handler)

let make_ui config connection use_gui : Zeroinstall.Ui.ui_handler =
  let use_gui =
    match use_gui, config.dry_run with
    | `Yes, true -> Safe_exn.failf "Can't use GUI with --dry-run"
    | (`Auto | `No), true -> `No
    | use_gui, false -> use_gui in

  match use_gui with
  | `No -> make_no_gui connection
  | `Yes | `Auto ->
      match Zeroinstall.Gui.try_get_gui config ~use_gui with
      | Some gui -> gui
      | None -> make_no_gui connection

let parse_restrictions = function
  | `Null -> XString.Map.empty
  | `Assoc items ->
      items |> List.fold_left (fun map (iface, expr) ->
        XString.Map.add iface (J.Util.to_string expr) map
      ) XString.Map.empty
  | json -> raise (J.Util.Type_error ("Not a map", json))

let parse_requirements json_assoc =
  let table = Hashtbl.create (List.length json_assoc) in
  json_assoc |> List.iter (fun (name, value) -> Hashtbl.add table name value);
  let pop name =
    match Hashtbl.find_opt table name with
    | None -> `Null
    | Some value ->
      Hashtbl.remove table name;
      value
  in
  let reqs =
    Zeroinstall.Requirements.({
      interface_uri = pop "interface" |> J.Util.to_string;
      command = pop "command" |> J.Util.to_string_option;
      source = pop "source" |> J.Util.to_bool_option |> default false;
      may_compile = pop "may_compile" |> J.Util.to_bool_option |> default false;
      extra_restrictions = pop "extra_restrictions" |> parse_restrictions;
      os = pop "os" |> J.Util.to_string_option |> pipe_some Arch.parse_os;
      cpu = pop "cpu" |> J.Util.to_string_option |> pipe_some Arch.parse_machine;
      message = pop "message" |> J.Util.to_string_option;
  }) in
  table |> Hashtbl.iter (fun name _ -> log_warning "Unexpected requirements field '%s'!" name);
  reqs

let select config tools (ui:Zeroinstall.Ui.ui_handler) requirements refresh =
  let success ~sels ~stale =
    let info = `Assoc [
      "stale", `Bool stale;
    ] in
    let json = `List [`String "ok"; info] in
    `WithXML (json, Zeroinstall.Selections.as_xml sels) |> Lwt.return in

  let select_with_refresh refresh =
    ui#run_solver tools `Select_only requirements ~refresh >>= function
    | `Success sels -> success ~sels ~stale:false
    | `Aborted_by_user -> `List [`String "aborted-by-user"] |> Lwt.return in

  if refresh || tools#use_gui = `Yes then select_with_refresh refresh
  else (
    let feed_provider = new Zeroinstall.Feed_provider_impl.feed_provider config tools#distro in
    match Zeroinstall.Solver.solve_for config feed_provider requirements with
    | (false, _results) ->
        log_info "Quick solve failed; can't select without updating feeds";
        select_with_refresh true
    | (true, results) ->
        let sels = Zeroinstall.Solver.selections results in
        success ~sels ~stale:feed_provider#have_stale_feeds
  )

(* Note: this function only supports the latest API. Previous APIs are handled using wrappers. *)
let handle_request config tools ui = function
  | "select", [`Assoc reqs; `Bool refresh] ->
      let requirements = parse_requirements reqs in
      Lwt.catch
        (fun () -> select config tools ui requirements refresh)
        (function
          | Safe_exn.T e ->
            let msg = Format.asprintf "%a" Safe_exn.pp e in
            `List [`String "fail"; `String msg] |> Lwt.return
          | ex -> Lwt.fail ex
        )
  | _ -> Lwt.return `Bad_request

(* Wrap for 2.6. Convert 2.6 requests and responses to/from 2.7 format. *)
let wrap_for_2_6 next (op, args) =
  match op with
  | "select" ->
      (* Strip out the new "status" response for old clients *)
      begin next (op, args) >|= function
      | `WithXML (`List [`String "ok"; _info], xml) -> `WithXML (`List [`String "ok"], xml)
      | x -> x end;
  | _ -> next (op, args)


let run_slave config tools ~from_peer ~to_peer ~requested_api_version =
  if requested_api_version < Version.parse "2.6" then
    Safe_exn.failf "Minimum supported API version is 2.6";
  let api_version = min requested_api_version Zeroinstall.About.parsed_version in
  let make_handler connection =
    let ui = make_ui config connection tools#use_gui in
    let handle_request = handle_request config tools ui in
    if api_version <= Version.parse "2.6" then wrap_for_2_6 handle_request
    else handle_request in
  let _connection, thread = JC.server ~api_version ~from_peer ~to_peer make_handler in
  thread >|= fun () ->
  log_info "OCaml slave exiting"

let handle options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  match args with
  | [requested_api_version] ->
      let requested_api_version = Version.parse requested_api_version in
      Lwt_main.run (run_slave options.config options.tools ~from_peer:Lwt_io.stdin ~to_peer:Lwt_io.stdout ~requested_api_version)
  | _ ->
      raise (Support.Argparse.Usage_error 1);
