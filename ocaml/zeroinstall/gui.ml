(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Manage the GUI sub-process. *)

open General
open Support.Common

module F = Feed
module R = Requirements
module U = Support.Utils
module Q = Support.Qdom

let string_of_ynm = function
  | Yes -> "yes"
  | No -> "no"
  | Maybe -> "maybe"

let get_impl (feed_provider:Feed_cache.feed_provider) sel =
  let iface = ZI.get_attribute F.attr_interface sel in
  let id = ZI.get_attribute F.attr_id sel in
  let from_feed = default iface @@ ZI.get_attribute_opt F.attr_from_feed sel in

  let get_override overrides =
    try Some (StringMap.find id overrides.F.user_stability)
    with Not_found -> None in

  match Feed_cache.parse_feed_url from_feed with
  | `distribution_feed master_feed_url -> (
      match feed_provider#get_feed master_feed_url with
      | None -> None
      | Some (master_feed, _) ->
          match feed_provider#get_distro_impls master_feed with
          | None -> None
          | Some (impls, overrides) ->
              let impl =
                try Some (List.find (fun impl -> F.get_attr_ex F.attr_id impl = id) impls)
                with Not_found -> None in
              match impl with
              | None -> None
              | Some impl -> Some (impl, get_override overrides)
  )
  | `local_feed _ | `remote_feed _ ->
      match feed_provider#get_feed from_feed with
      | None -> None
      | Some (feed, overrides) ->
          Some (StringMap.find id feed.F.implementations, get_override overrides)

let format_size size =
  let spf = Printf.sprintf in
  if size < 2048. then spf "%.0f bytes" size
  else (
    let rec check size units =
      let size = size /. 1024. in
      match units with
      | u::rest ->
          if size < 2048. || rest = [] then
            spf "%.1f %s" size u
          else check size rest
      | [] -> assert false in
    check size ["KB"; "MB"; "GB"; "TB"]
  )

let get_download_size info impl =
  match info.F.retrieval_methods with
  | [] -> Q.raise_elem "Implementation %s has no retrieval methods!" (F.get_attr_ex F.attr_id impl) impl.F.qdom
  | methods ->
      let size = U.first_match methods ~f:(fun m ->
        match Recipe.parse_retrieval_method m with
        | Some recipe -> Some (Recipe.get_download_size recipe)
        | None -> None
      ) in
      match size with
      | Some size -> size
      | None -> Q.raise_elem "Implementation %s has no usable retrieval methods!" (F.get_attr_ex F.attr_id impl) impl.F.qdom

(* Returns (local-dir, fetch-size, fetch-tooltip) *)
let get_fetch_info config impl =
  try
    match impl.F.impl_type with
    | F.LocalImpl path -> (`String path, "(local)", path)
    | F.CacheImpl info -> (
        match Stores.lookup_maybe config.system info.F.digests config.stores with
        | None ->
          let size = get_download_size info impl in
          let pretty = format_size (Int64.to_float size) in
          (`Null, pretty, Printf.sprintf "Need to download %s (%s bytes)" pretty (Int64.to_string size))
        | Some path -> (`String path, "(cached)", "This version is already stored on your computer.")
    )
    | F.PackageImpl info ->
        if info.F.package_installed then (`Null, "(package)", "This distribution-provided package is already installed.")
        else (
          let size =
            match info.F.retrieval_method with
            | None -> None
            | Some attrs ->
                try Some (Yojson.Basic.Util.to_float (List.assoc "size" attrs))
                with Not_found -> None in
          match size with
          | None -> (`Null, "(install)", "No size information available for this download")
          | Some size ->
              let pretty = format_size size in
              (`Null, pretty, Printf.sprintf "Distribution package: need to download %s (%s bytes)" pretty (string_of_float size))
        )
  with Safe_exception (msg, _) as ex ->
    log_warning ~ex "get_fetch_info";
    (`Null, "ERROR", msg)

let build_tree config (feed_provider:Feed_cache.feed_provider) old_sels sels : Yojson.Basic.json =
  let rec process_tree (uri, details) =
    let (name, summary) =
      match feed_provider#get_feed uri with
      | Some (main_feed, _overrides) ->
          (main_feed.F.name, default "-" @@ F.get_summary config.langs main_feed);
      | None ->
          (uri, "") in

    let about_feed = [
      ("interface", `String uri);
      ("name", `String name);
      ("summary", `String summary);
    ] in

    match details with
    | `Selected (sel, children) -> (
        match get_impl feed_provider sel with
        | None -> `Assoc (("type", `String "error") :: about_feed)
        | Some (impl, user_stability) ->
            let orig_sel =
              try Some (StringMap.find uri old_sels)
              with Not_found -> None in

            let version = ZI.get_attribute F.attr_version sel in
            let stability =
              match user_stability with
              | Some s -> String.uppercase (F.format_stability s)
              | None -> F.get_attr_ex F.attr_stability impl in
            let prev_version =
              match orig_sel with
              | None -> None
              | Some old_sel ->
                  let old_version = ZI.get_attribute F.attr_version old_sel in
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

            let from_feed = default uri @@ ZI.get_attribute_opt F.attr_from_feed sel in
            let id = ZI.get_attribute F.attr_id sel in

            let (_dir, fetch_str, fetch_tip) = get_fetch_info config impl in

            `Assoc (
              ("type", `String "selected") ::
              ("version", `String version_str) ::
              ("version-tip", `String version_tip) ::
              ("fetch", `String fetch_str) ::
              ("fetch-tip", `String fetch_tip) ::
              ("from-feed", `String from_feed) ::
              ("id", `String id) ::
              ("children", `List (List.map process_tree children)) ::
                about_feed)
    )
    | `Problem -> `Assoc (("type", `String "problem") :: about_feed) in

  process_tree @@ Tree.as_tree sels

let string_of_feed_type =
  let open Feed in
  function
  | Feed_import             -> "feed-import"
  | User_registered         -> "user-registered"
  | Site_packages           -> "site-packages"
  | Distro_packages         -> "distro-packages"

(** Return the feed list to display in the GUI's Feeds tab. *)
let list_feeds feed_provider iface =
  let iface_config = feed_provider#get_iface_config iface in
  let extra_feeds = iface_config.Feed_cache.extra_feeds in

  let imported_feeds =
    match feed_provider#get_feed iface with
    | None -> []
    | Some (feed, _overrides) -> feed.Feed.imported_feeds in

  let main = Feed.({
    feed_src = iface;
    feed_os = None;
    feed_machine = None;
    feed_langs = None;
    feed_type = Feed_import;
  }) in

  ListLabels.map (main :: (imported_feeds @ extra_feeds)) ~f:(fun feed ->
    let arch =
      match feed.F.feed_os, feed.F.feed_machine with
      | None, None -> ""
      | os, machine -> Arch.format_arch os machine in
    `Assoc [
      ("url", `String feed.F.feed_src);
      ("arch", `String arch);
      ("type", `String (string_of_feed_type feed.F.feed_type));
    ]
  )

let list_impls config (results:Solver.result) iface =
  let make_list ~source selected_impl =
    let candidates = results#impl_provider#get_implementations iface ~source in

    let by_version (a,_) (b,_) = compare b.F.parsed_version a.F.parsed_version in

    let open Impl_provider in
    let good_impls = List.map (fun i -> (i, None)) candidates.impls in
    let bad_impls = List.map (fun (i, prob) -> (i, Some prob)) candidates.rejects in
    let all_impls = List.sort by_version @@ good_impls @ bad_impls in

    let impls =
      `List (ListLabels.map all_impls ~f:(fun (impl, problem) ->
        let impl_id = F.get_attr_ex F.attr_id impl in
        let notes =
          match problem with
          | None -> "None"
          | Some problem -> Impl_provider.describe_problem impl problem in
        let from_feed = F.get_attr_ex F.attr_from_feed impl in
        let overrides = Feed.load_feed_overrides config from_feed in
        let user_stability =
          try `String (F.format_stability @@ StringMap.find impl_id overrides.F.user_stability)
          with Not_found -> `Null in
        let arch =
          match impl.F.os, impl.F.machine with
          | None, None -> "any"
          | os, machine -> Arch.format_arch os machine in
        let upstream_stability = F.get_attr_ex F.attr_stability impl in    (* (note: impl.stability is overall stability) *)
        let (impl_dir, fetch, tooltip) = get_fetch_info config impl in

        `Assoc [
          ("from-feed", `String from_feed);
          ("id", `String impl_id);
          ("version", `String (F.get_attr_ex F.attr_version impl));
          ("released", `String (default "-" @@ F.get_attr_opt F.attr_released impl.F.props.F.attrs));
          ("fetch", `String fetch);
          ("stability", `String upstream_stability);
          ("user-stability", user_stability);
          ("arch", `String arch);
          ("langs", `String (default "-" @@ F.get_attr_opt F.attr_langs impl.F.props.F.attrs));
          ("notes", `String notes);
          ("tooltip", `String tooltip);
          ("usable", `Bool (problem = None));
          ("impl-dir", impl_dir);
        ]
      )) in

    if selected_impl.F.parsed_version = Versions.dummy then
      [ ("implementations", impls) ]
    else
      [
        ("selected-feed", `String (F.get_attr_ex F.attr_from_feed selected_impl));
        ("selected-id", `String (F.get_attr_ex F.attr_id selected_impl));
        ("implementations", impls)
      ] in

  let get_selected ~source =
    match results#impl_cache#peek (iface, source) with
    | None -> None
    | Some candidates ->
        match candidates#get_selected with
        | None -> None
        | Some (_lit, impl) -> Some impl in     (* Also true for [dummy_impl] *)

  match get_selected ~source:true with
  | Some source_impl -> make_list ~source:true source_impl
  | None ->
      match get_selected ~source:false with
      | Some bin_impl -> make_list ~source:false bin_impl
      | None ->
          (* We didn't look at this interface at all, so no information will be cached.
           * There's a risk of deadlock if we try to fetch distro candidates in the callback, so
           * we return nothing, which will cause the GUI to shade the dialog. *)
          []

(** Download the archives. Called when the user clicks the 'Run' button. *)
let download_archives (fetcher:Fetch.fetcher) distro = function
  | (false, _) -> raise_safe "Can't download archives; solve failed!"
  | (true, results) ->
      let sels = results#get_selections in
      match_lwt fetcher#download_selections ~distro sels with
      | `success -> Lwt.return (`String "ok")
      | `aborted_by_user -> Lwt.return (`String "aborted-by-user")

(** Run the GUI to choose and download a set of implementations
 * If [use_gui] is No; just returns `Dont_use_GUI.
 * If Maybe, uses the GUI if possible.
 * If Yes, uses the GUI or throws an exception.
 * [test_callback] is used if the user clicks on the test button in the bug report dialog.
 *)
let get_selections_gui config (slave:Python.slave) ?test_callback distro ?(systray=false) mode reqs ~refresh ~use_gui =
  if use_gui = No then `Dont_use_GUI
  else if config.dry_run then (
    if use_gui = Maybe then `Dont_use_GUI
    else raise_safe "Can't use GUI with --dry-run"
  ) else if config.system#getenv "DISPLAY" = None then (
    if use_gui = Maybe then `Dont_use_GUI
    else raise_safe "Can't use GUI because $DISPLAY is not set"
  ) else if not (slave#invoke (`List [`String "check-gui"; `String (string_of_ynm use_gui)]) Yojson.Basic.Util.to_bool) then (
    `Dont_use_GUI       (* [check-gui] will throw if use_gui is [Yes] *)
  ) else (
    let fetcher = new Fetch.fetcher config slave in
    let feed_provider = ref (new Feed_cache.feed_provider config distro) in

    let original_solve = Solver.solve_for config !feed_provider reqs in
    let original_selections =
      match original_solve with
      | (false, _) -> StringMap.empty
      | (true, results) -> Selections.make_selection_map results#get_selections in

    let results = ref original_solve in

    let watcher =
      object
        method update (ready, new_results) =
          results := (ready, new_results);
          Python.async (fun () ->
            let sels = new_results#get_selections in
            let tree = build_tree config !feed_provider original_selections sels in
            slave#invoke_async ~xml:sels (`List [`String "gui-update-selections"; `Bool ready; tree]) ignore
          )

        method report ex =
          Python.async (fun () ->
            log_info ~ex "Sending error to GUI";
            let msg = Printexc.to_string ex in
            slave#invoke_async (`List [`String "report-error"; `String msg]) ignore
          )
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

    Python.register_handler "download-archives" (function
      | [] -> (
          match mode with
          | `Select_only -> Lwt.return (`String "ok")
          | `Download_only | `Select_for_run -> download_archives fetcher distro !results
      )
      | json -> raise_safe "download-archives: invalid request: %s" (Yojson.Basic.to_string (`List json))
    );

    Python.register_handler "get-bug-report-details" (function
      | [] -> Lwt.return (
          let (ready, results) = !results in
          let sels = results#get_selections in
          let details =
            if ready then (
              let buf = Buffer.create 1000 in
              Tree.print config (Buffer.add_string buf) sels;
              Buffer.contents buf
            ) else (
              Diagnostics.get_failure_reason config results
            ) in
          `Assoc [
            ("details", `String details);
            ("xml", `String (Q.to_utf8 sels));
          ]
      )
      | json -> raise_safe "get_bug_report_details: invalid request: %s" (Yojson.Basic.to_string (`List json))
    );

    Python.register_handler "get-component-details" (function
      | [`String uri] -> Lwt.return (`Assoc (
          ("feeds", `List (list_feeds !feed_provider uri)) ::
          list_impls config (snd !results) uri
        );
      )
      | json -> raise_safe "get_component_details: invalid request: %s" (Yojson.Basic.to_string (`List json))
    );

    Python.register_handler "justify-decision" (function
      | [`String iface; `String feed; `String id] ->
          let reason = Diagnostics.justify_decision config !feed_provider reqs iface F.({feed; id}) in
          Lwt.return (`String reason)
      | json -> raise_safe "justify_decision: invalid request: %s" (Yojson.Basic.to_string (`List json))
    );

    Python.register_handler "run-test" (function
      | [] -> (
          match test_callback with
          | None -> raise_safe "Can't do a test run - no test callback registered (sorry)"
          | Some test_callback ->
              let (ready, results) = !results in
              if ready then (
                lwt result = test_callback results#get_selections in
                Lwt.return (`String result)
              ) else raise_safe "Can't do a test run - solve failed"
      )
      | json -> raise_safe "run_test: invalid request: %s" (Yojson.Basic.to_string (`List json))
    );

    slave#invoke (`List [`String "open-gui"; `String reqs.Requirements.interface_uri; opts]) (function
      | `List [] -> ()
      | json -> raise_safe "Invalid JSON response: %s" (Yojson.Basic.to_string json)
    );

    (* This is a bit awkward. Driver calls Solver, which calls Impl_provider, which calls Distro, which needs
     * to make synchronous calls on the slave. However, Lwt doesn't support nested run loops. Therefore, each time
     * we need to solve we exit the loop and run the driver, which creates its own loops as needed.
     * Possible alternatives:
     * - Make Solver async. But we'd want to put it back again once distro is ported.
     * - Make Distro delay downloads when invoked via Driver but not when invoked directly. Also messy.
     *)
    let rec loop force =
      feed_provider := new Feed_cache.feed_provider config distro;
      let (ready, results) = Driver.solve_with_downloads config fetcher ~feed_provider:!feed_provider ~watcher distro reqs ~force ~update_local:true in
      let response =
        slave#invoke (`List [`String "run-gui"]) (function
          | `List [`String "ok"] -> assert ready; `Success results#get_selections
          | `List [`String "cancel"] -> `Aborted_by_user
          | `List [`String "recalculate"; `Bool force] -> `Recalculate force
          | json -> raise_safe "get_selections_gui: invalid response: %s" (Yojson.Basic.to_string json)
      ) in
      match response with
      | `Recalculate force -> Config.load_config config; loop force
      | `Aborted_by_user -> `Aborted_by_user
      | `Success sels -> `Success sels in

    loop refresh
  )
