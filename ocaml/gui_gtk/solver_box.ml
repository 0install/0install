(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main GUI window showing the progress of a solve. *)

open Support.Common
open Zeroinstall.General

module Python = Zeroinstall.Python
module F = Zeroinstall.Feed
module FC = Zeroinstall.Feed_cache
module FeedAttr = Zeroinstall.Constants.FeedAttr
module Feed_url = Zeroinstall.Feed_url
module Driver = Zeroinstall.Driver
module Requirements = Zeroinstall.Requirements

let first_para text =
  let first =
    try
      let index = Str.search_forward (Str.regexp_string "\n\n") text 0 in
      String.sub text 0 index
    with Not_found -> text in
  Str.global_replace (Str.regexp_string "\n") " " first |> trim

(** Download the archives. Called when the user clicks the 'Run' button. *)
let download_archives ~feed_provider driver = function
  | (false, _) -> raise_safe "Can't download archives; solve failed!"
  | (true, results) ->
      let sels = results#get_selections in
      match_lwt driver#download_selections ~include_packages:true ~feed_provider sels with
      | `success -> Lwt.return (`String "ok")
      | `aborted_by_user -> Lwt.return (`String "aborted-by-user")

let build_tree config (feed_provider:Zeroinstall.Feed_provider.feed_provider) old_sels sels : Yojson.Basic.json =
  let rec process_tree (uri, details) =
    let (name, summary, description, feed_imports) =
      match feed_provider#get_feed (Zeroinstall.Feed_url.master_feed_of_iface uri) with
      | Some (main_feed, _overrides) ->
          (main_feed.F.name,
           default "-" @@ F.get_summary config.langs main_feed,
           F.get_description config.langs main_feed,
           main_feed.F.imported_feeds);
      | None ->
          (uri, "", None, []) in

    (* This is the set of feeds corresponding to this interface. It's used to correlate downloads with
     * components in the GUI.
     * Note: "distribution:" feeds give their master feed as their hint, so are not included here. *)
    let user_feeds = (feed_provider#get_iface_config uri).FC.extra_feeds in
    let all_feeds = uri :: (user_feeds @ feed_imports |> List.map (fun {F.feed_src; _} -> Zeroinstall.Feed_url.format_url feed_src)) in

    let about_feed = [
      ("interface", `String uri);
      ("name", `String name);
      ("summary", `String summary);
      ("summary-tip", `String (default "(no description available)" description |> first_para));
      ("may-compile", `Bool (Zeroinstall.Gui.have_source_for feed_provider uri));
      ("all-feeds", `List (all_feeds |> List.map (fun s -> `String s)));
    ] in

    match details with
    | `Selected (sel, children) -> (
        match Zeroinstall.Gui.get_impl feed_provider sel with
        | None -> `Assoc (("type", `String "error") :: about_feed)
        | Some (impl, user_stability) ->
            let orig_sel = StringMap.find uri old_sels in

            let version = ZI.get_attribute FeedAttr.version sel in
            let stability =
              match user_stability with
              | Some s -> String.uppercase (F.format_stability s)
              | None -> F.get_attr_ex FeedAttr.stability impl in
            let prev_version =
              match orig_sel with
              | None -> None
              | Some old_sel ->
                  let old_version = ZI.get_attribute FeedAttr.version old_sel in
                  if old_version = version then None
                  else Some old_version in
            let version_str =
              match prev_version with
              | Some prev_version -> Printf.sprintf "%s (was %s)" version prev_version
              | _ -> version in
            let version_tip =
              let current = Printf.sprintf "Currently preferred version: %s (%s)" version stability in
              match prev_version with
              | Some prev_version -> Printf.sprintf "%s\nPreviously preferred version: %s" current prev_version
              | _ -> current in

            let {F.id; F.feed = from_feed} = Zeroinstall.Selections.get_id sel in

            let (fetch_str, fetch_tip) = Zeroinstall.Gui.get_fetch_info config impl in

            `Assoc (
              ("type", `String "selected") ::
              ("version", `String version_str) ::
              ("version-tip", `String version_tip) ::
              ("fetch", `String fetch_str) ::
              ("fetch-tip", `String fetch_tip) ::
              ("from-feed", `String (Feed_url.format_url from_feed)) ::
              ("id", `String id) ::
              ("children", `List (List.map process_tree children)) ::
                about_feed)
    )
    | `Problem -> `Assoc (("type", `String "problem") :: about_feed) in

  process_tree @@ Zeroinstall.Tree.as_tree sels

let add_slave_handlers (gui:Zeroinstall.Gui.gui_ui) (driver:Driver.driver) ~show_component ~report_bug ?test_callback mode results feed_provider =
  let config = driver#config in
  let distro = driver#distro in
  let fetcher = driver#fetcher in

  let show_bug_report_dialog iface =
    let run_test = test_callback |> pipe_some (fun test_callback ->
      Some (fun () -> Zeroinstall.Gui.run_test config distro test_callback !results)
    ) in
    report_bug ?run_test iface in

  Python.register_handler "download-archives" (function
    | [] -> (
        match mode with
        | `Select_only -> Lwt.return (`String "ok")
        | `Download_only | `Select_for_run -> download_archives ~feed_provider:!feed_provider driver !results
    )
    | json -> raise_safe "download-archives: invalid request: %s" (Yojson.Basic.to_string (`List json))
  );

  Python.register_handler "download-icon" (function
    | [`String feed_url] ->
        let feed = Feed_url.parse_non_distro feed_url in
        Zeroinstall.Gui.download_icon config fetcher#downloader !feed_provider feed >> Lwt.return `Null
    | json -> raise_safe "download-icon: invalid request: %s" (Yojson.Basic.to_string (`List json))
  );

  Python.register_handler "show-preferences" (function
    | [] -> gui#show_preferences >> Lwt.return `Null
    | json -> raise_safe "show-preferences: invalid request: %s" (Yojson.Basic.to_string (`List json))
  );

  Python.register_handler "show-component-dialog" (function
    | [`String iface; `Bool select_versions_tab] ->
        show_component ~driver iface ~select_versions_tab;
        Lwt.return `Null
    | json -> raise_safe "show-component-dialog: invalid request: %s" (Yojson.Basic.to_string (`List json))
  );

  Python.register_handler "show-bug-report-dialog" (function
    | [`String iface] ->
        show_bug_report_dialog iface;
        Lwt.return `Null
    | json -> raise_safe "show-bug-report-dialog: invalid request: %s" (Yojson.Basic.to_string (`List json))
  );

  Python.register_handler "gui-compile" (function
    | [`String iface; `Bool autocompile] -> Zeroinstall.Gui.compile config !feed_provider iface ~autocompile >> Lwt.return `Null
    | json -> raise_safe "gui-compile: invalid request: %s" (Yojson.Basic.to_string (`List json))
  )

class type solver_box =
  object
    method recalculate : unit
    method result : [`Aborted_by_user | `Success of Support.Qdom.element ] Lwt.t
  end

let run_solver config (gui:Zeroinstall.Gui.gui_ui) (slave:Python.slave) trust_db driver ?test_callback ?(systray=false) mode reqs ~refresh : solver_box =
  let last_update = ref None in
  let component_boxes = ref StringMap.empty in

  let report_bug ?run_test iface =
    let (_reqs, (results, _fp)) = !last_update |? lazy (failwith "BUG: no results") in   (* todo: improve this *)
    Bug_report_box.create ?run_test ?last_error:!Alert_box.last_error config ~iface ~results in

  let recalculate () =
    Python.async (fun () -> slave#invoke "gui-recalculate" [] Python.expect_null) in

  let show_component ~driver iface ~select_versions_tab =
    match StringMap.find iface !component_boxes with
    | Some box -> box#dialog#present ()
    | None ->
        let box = Component_box.create config trust_db driver iface ~recalculate ~select_versions_tab in
        component_boxes := !component_boxes |> StringMap.add iface box;
        box#dialog#connect#destroy ~callback:(fun () -> component_boxes := !component_boxes |> StringMap.remove iface) |> ignore;
        !last_update |> if_some box#update;
        box#dialog#show () in

  let feed_provider = ref (new Zeroinstall.Feed_provider.feed_provider config driver#distro) in

  let original_solve = Zeroinstall.Solver.solve_for config !feed_provider reqs in
  let original_selections =
    match original_solve with
    | (false, _) -> StringMap.empty
    | (true, results) -> Zeroinstall.Selections.make_selection_map results#get_selections in

  let results = ref original_solve in

  let update reqs results : unit =
    last_update := Some (reqs, results);
    !component_boxes |> StringMap.iter (fun _iface box ->
      box#update (reqs, results)
    );

    Python.async (fun () ->
      let ((ready, new_results), new_fp) = results in
      let sels = new_results#get_selections in
      let tree = build_tree config new_fp original_selections sels in
      slave#invoke ~xml:sels "gui-update-selections" [`Bool ready; tree] Zeroinstall.Python.expect_null
    ) in

  let watcher =
    object (_ : Driver.watcher)
      method update (((ready, new_results), new_fp) as result) =
        feed_provider := new_fp;
        results := (ready, new_results);

        update reqs result;

      method report feed_url msg =
        Alert_box.report_error @@ Safe_exception (Printf.sprintf "Feed '%s': %s" (Feed_url.format_url feed_url) msg, ref [])
    end in

  let action = match mode with
  | `Select_only -> "for-select"
  | `Download_only -> "for-download"
  | `Select_for_run -> "for-run" in

  let opts = `Assoc [
    ("refresh", `Bool refresh);
    ("action", `String action);
    ("systray", `Bool systray);
  ] in

  add_slave_handlers gui driver ?test_callback ~show_component ~report_bug mode results feed_provider;

  let result =
    lwt () =
      slave#invoke "open-gui" [`String reqs.Requirements.interface_uri; opts] (function
        | `List [] -> ()
        | json -> raise_safe "Invalid JSON response: %s" (Yojson.Basic.to_string json)
      ) in

    (* Note: This can be tidied up now that distro has been ported. *)
    let rec loop force =
      lwt (ready, results, _feed_provider) = driver#solve_with_downloads ~watcher reqs ~force ~update_local:true in
      lwt response =
        slave#invoke "run-gui" [] (function
          | `List [`String "ok"] -> assert ready; `Success results#get_selections
          | `List [`String "cancel"] -> `Aborted_by_user
          | `List [`String "recalculate"; `Bool force] -> `Recalculate force
          | json -> raise_safe "get_selections_gui: invalid response: %s" (Yojson.Basic.to_string json)
        ) in
      match response with
      | `Recalculate force -> Zeroinstall.Config.load_config config; loop force
      | `Aborted_by_user -> Lwt.return `Aborted_by_user
      | `Success sels -> Lwt.return (`Success sels) in

    loop refresh in

  object
    method recalculate = recalculate ()
    method result = result
  end
