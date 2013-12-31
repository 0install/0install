(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Manage the GUI sub-process. *)

open General
open Support.Common

module Basedir = Support.Basedir
module FeedAttr = Constants.FeedAttr
module F = Feed
module R = Requirements
module U = Support.Utils
module Q = Support.Qdom
module G = Support.Gpg

let gui_plugin = ref None

let register_plugin fn =
  gui_plugin := Some fn

let get_impl (feed_provider:Feed_provider.feed_provider) sel =
  let {Feed_url.id; Feed_url.feed = from_feed} = Selections.get_id sel in

  let get_override overrides =
    StringMap.find id overrides.F.user_stability in

  match from_feed with
  | `distribution_feed master_feed_url -> (
      match feed_provider#get_feed master_feed_url with
      | None -> None
      | Some (master_feed, _) ->
          let (impls, overrides) = feed_provider#get_distro_impls master_feed in
          match StringMap.find id impls with
          | None -> None
          | Some impl -> Some ((impl :> F.generic_implementation), get_override overrides)
  )
  | (`local_feed _ | `remote_feed _) as feed_url ->
      match feed_provider#get_feed feed_url with
      | None -> None
      | Some (feed, overrides) ->
          Some (StringMap.find_safe id feed.F.implementations, get_override overrides)

let get_download_size info impl =
  match info.F.retrieval_methods with
  | [] -> log_info "Implementation %s has no retrieval methods!" (F.get_attr_ex FeedAttr.id impl); None
  | methods ->
      methods |> U.first_match (fun m ->
        match Recipe.parse_retrieval_method m with
        | Some recipe -> Some (Recipe.get_download_size recipe)
        | None -> log_info "Implementation %s has no usable retrieval methods!" (F.get_attr_ex FeedAttr.id impl); None
      )

let get_fetch_info config impl =
  try
    match impl.F.impl_type with
    | `local_impl path -> ("(local)", path)
    | `cache_impl info -> (
        match Stores.lookup_maybe config.system info.F.digests config.stores with
        | None ->
          begin match get_download_size info impl with
          | Some size ->
              let pretty = U.format_size size in
              (pretty, Printf.sprintf "Need to download %s (%s bytes)" pretty (Int64.to_string size))
          | None -> ("-", "No size") end;
        | Some path -> ("(cached)", "This version is already stored on your computer:\n" ^ path)
    )
    | `package_impl info ->
        if info.F.package_installed then ("(package)", "This distribution-provided package is already installed.")
        else (
          let size =
            match info.F.retrieval_method with
            | None -> None
            | Some retrieval_method -> retrieval_method.F.distro_size |> pipe_some (fun s -> Some (Int64.to_float s)) in
          match size with
          | None -> ("(install)", "No size information available for this download")
          | Some size ->
              let pretty = U.format_size (Int64.of_float size) in
              (pretty, Printf.sprintf "Distribution package: need to download %s (%s bytes)" pretty (string_of_float size))
        )
  with Safe_exception (msg, _) as ex ->
    log_warning ~ex "get_fetch_info";
    ("ERROR", msg)

let have_source_for feed_provider iface =
  let master_feed = Feed_url.master_feed_of_iface iface in
  let user_feeds = (feed_provider#get_iface_config iface).Feed_cache.extra_feeds in
  let imported =
    match feed_provider#get_feed master_feed with
    | None -> []
    | Some (feed, _overrides) -> feed.Feed.imported_feeds in

  let have_source = ref false in
  let to_check = ref [master_feed] in

  (user_feeds @ imported) |> List.iter (fun feed_import ->
    match feed_import.Feed.feed_machine with
    | Some "src" -> have_source := true   (* Source-only feed *)
    | Some _ -> ()    (* Binary-only feed; can't contain source *)
    | None -> to_check := feed_import.Feed.feed_src :: !to_check (* Mixed *)
  );

  if !have_source then true
  else (
    (* Don't have any src feeds. Do we have a source implementation
     * as part of a regular feed? *)

    (* Copy feed_provider so we don't mark any feeds as used.
     * For example, a Windows-* feed might contain source, but if
     * haven't cached it then there's no point checking it. *)
    let feed_provider = Oo.copy feed_provider in
    !to_check |> List.exists (fun url ->
      match feed_provider#get_feed url with
      | None -> false
      | Some (feed, _overrides) ->
          feed.Feed.implementations |> StringMap.exists (fun _id impl -> Feed.is_source impl)
    )
  )

let list_impls (results:Solver.result) iface =
  let make_list ~source selected_impl =
    let candidates = results#impl_provider#get_implementations iface ~source in

    let by_version (a,_) (b,_) = compare b.F.parsed_version a.F.parsed_version in

    let open Impl_provider in
    let good_impls = List.map (fun i -> (i, None)) candidates.impls in
    let bad_impls = List.map (fun (i, prob) -> (i, Some prob)) candidates.rejects in
    let all_impls = List.sort by_version @@ good_impls @ bad_impls in

    let selected_impl =
      if selected_impl.F.parsed_version = Versions.dummy then None else Some selected_impl in

    Some (selected_impl, all_impls) in

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
          None

(** Download an icon for this feed and add it to the
    icon cache. If the feed has no icon do nothing. *)
let download_icon (fetcher:Fetch.fetcher) (feed_provider:Feed_provider.feed_provider) parsed_url =
  let feed_url = Feed_url.format_url parsed_url in
  log_debug "download_icon %s" feed_url;

  let parsed_url = Feed_url.parse_non_distro feed_url in

  let icon_url =
    match feed_provider#get_feed parsed_url with
    | None -> None
    | Some (feed, _) ->
        (* Find a suitable icon to download *)
        feed.F.root.Q.child_nodes |> U.first_match (fun child ->
          match ZI.tag child with
          | Some "icon" -> (
              match ZI.get_attribute_opt "type" child with
              | Some "image/png" -> ZI.get_attribute_opt "href" child
              | _ -> log_debug "Skipping non-PNG icon"; None
          )
          | _ -> None
        ) in

  match icon_url with
  | None -> log_info "No PNG icons found in %s" feed_url; Lwt.return ()
  | Some href ->
      fetcher#download_icon parsed_url href

let add_feed config iface feed_url =
  let (`remote_feed url | `local_feed url) = feed_url in

  let feed = Feed_cache.get_cached_feed config feed_url |? lazy (raise_safe "Failed to read new feed!") in
  match Feed.get_feed_targets feed with
  | [] -> raise_safe "Feed '%s' is not a feed for '%s'" url iface
  | feed_for when List.mem iface feed_for ->
      let user_import = Feed.make_user_import feed_url in
      let iface_config = Feed_cache.load_iface_config config iface in

      let extra_feeds = iface_config.Feed_cache.extra_feeds in
      if List.mem user_import extra_feeds then (
        raise_safe "Feed from '%s' has already been added!" url
      ) else (
        let extra_feeds = user_import :: extra_feeds in
        Feed_cache.save_iface_config config iface {iface_config with Feed_cache.extra_feeds};
      );
  | feed_for -> raise_safe "This is not a feed for '%s'.\nOnly for:\n%s" iface (String.concat "\n" feed_for)

let add_remote_feed config fetcher iface (feed_url:[`remote_feed of feed_url]) =
  match_lwt Driver.download_and_import_feed fetcher feed_url with
  | `aborted_by_user -> Lwt.return ()
  | `success _ | `no_update -> add_feed config iface feed_url; Lwt.return ()

let remove_feed config iface feed_url =
  let iface_config = Feed_cache.load_iface_config config iface in
  let user_import = Feed.make_user_import feed_url in
  let extra_feeds = iface_config.Feed_cache.extra_feeds |> List.filter ((<>) user_import) in
  if iface_config.Feed_cache.extra_feeds = extra_feeds then (
    raise_safe "Can't remove '%s'; it is not a user-added feed of %s" (Feed_url.format_url feed_url) iface;
  ) else (
    Feed_cache.save_iface_config config iface {iface_config with Feed_cache.extra_feeds};
  )

let set_impl_stability config {Feed_url.feed; Feed_url.id} rating =
  let overrides = Feed.load_feed_overrides config feed in
  let overrides = {
    overrides with F.user_stability =
      match rating with
      | None -> StringMap.remove id overrides.F.user_stability
      | Some rating -> StringMap.add id rating overrides.F.user_stability
  } in
  F.save_feed_overrides config feed overrides

(** Run [argv] and return its stdout on success.
 * On error, report both stdout and stderr. *)
let run_subprocess argv =
  log_info "Running %s" (Support.Logging.format_argv_for_logging (Array.to_list argv));
  try_lwt
    let command = (argv.(0), argv) in
    let child = Lwt_process.open_process_full command in
    lwt () = Lwt_io.close child#stdin in
    lwt stdout = Lwt_io.read child#stdout
    and stderr = Lwt_io.read child#stderr in
    match_lwt child#close with
    | Unix.WEXITED 0 -> Lwt.return stdout
    | status ->
        let output = stdout ^ stderr in
        if output = "" then Support.System.check_exit_status status;
        raise_safe "Compile failed: %s" output
  with Safe_exception _ as ex ->
    reraise_with_context ex "... executing %s" (Support.Logging.format_argv_for_logging (Array.to_list argv))

let build_and_register config iface min_0compile_version =
  lwt _ =
    run_subprocess [|
      config.abspath_0install; "run";
      "--message"; "Download the 0compile tool, to compile the source code";
      "--not-before=" ^ (Versions.format_version min_0compile_version);
      "http://0install.net/2006/interfaces/0compile.xml";
      "gui";
      iface
    |] in
  Lwt.return ()

(* Running subprocesses is a bit messy; this is just a direct translation of the (old) Python code. *)
let compile config feed_provider iface ~autocompile =
  let our_min_version = Versions.parse_version "1.0" in     (* The oldest version of 0compile we support *)

  lwt () =
    if autocompile then (
      lwt _ =
        run_subprocess [|
          config.abspath_0install; "run";
          "--message"; "Download the 0compile tool to compile the source code";
          "--not-before=" ^ (Versions.format_version our_min_version);
          "http://0install.net/2006/interfaces/0compile.xml";
          "autocompile";
          "--gui";
          "--"; iface;
        |] in Lwt.return ()
    ) else (
      (* Prompt user to choose source version *)
      lwt stdout = run_subprocess [|
        config.abspath_0install; "download"; "--xml";
        "--message"; "Download the source code to be compiled";
        "--gui"; "--source";
        "--"; iface;
      |] in
      let root = `String (0, stdout) |> Xmlm.make_input |> Q.parse_input None in
      let sels = Selections.create root in
      let sel = Selections.find iface sels in
      let sel = sel |? lazy (raise_safe "No implementation of root (%s)!" iface) in
      let min_version =
        match Q.get_attribute_opt (COMPILE_NS.ns, "min-version") sel with
        | None -> our_min_version
        | Some min_version -> max our_min_version (Versions.parse_version min_version) in
      build_and_register config iface min_version
    ) in

  (* A new local feed may have been registered, so reload it from the disk cache *)
  log_info "0compile command completed successfully. Reloading interface details.";
  feed_provider#forget_user_feeds iface;
  Lwt.return ()      (* The plugin should now recalculate *)

let get_bug_report_details config ~iface (ready, results) =
  let system = config.system in
  let sels = results#get_selections in
  let root_iface = Selections.root_iface sels in

  let issue_file = "/etc/issue" in
  let issue =
    if system#file_exists issue_file then
      U.read_file system issue_file |> trim
    else
      Printf.sprintf "(file '%s' not found)" issue_file in

  let b = Buffer.create 1000 in
  let add fmt =
    let do_add msg = Buffer.add_string b msg in
    Printf.ksprintf do_add fmt in

  add "Problem with %s\n" iface;
  if iface <> root_iface then
    add "  (while attempting to run %s)\n" root_iface;
  add "\n";

  add "0install version %s\n" About.version;

  if ready then (
    Tree.print config (Buffer.add_string b) sels
  ) else (
    Buffer.add_string b @@ Diagnostics.get_failure_reason config results
  );

  let platform = system#platform in
  add "\n\
       \nSystem:\
       \n  %s %s %s\n\
       \nIssue:\
       \n  %s\n" platform.Platform.os platform.Platform.release platform.Platform.machine issue;

  add "\n%s" @@ Support.Qdom.to_utf8 (Selections.as_xml sels);

  Buffer.contents b

let run_test config distro test_callback (ready, results) =
  try_lwt
    if ready then (
      let sels = results#get_selections in
      match Driver.get_unavailable_selections config ~distro sels with
      | [] -> test_callback sels
      | missing ->
          let details =
            missing |> List.map (fun sel ->
              Printf.sprintf "%s version %s\n  (%s)"
                (ZI.get_attribute FeedAttr.interface sel)
                (ZI.get_attribute FeedAttr.version sel)
                (ZI.get_attribute FeedAttr.id sel)
            ) |> String.concat "\n\n- " in
          raise_safe "Can't run: the chosen versions have not been downloaded yet. I need:\n\n- %s" details
    ) else raise_safe "Can't do a test run - solve failed"
  with Safe_exception _ as ex ->
    Lwt.return (Printexc.to_string ex)

let try_get_gui config ~use_gui =
  let system = config.system in
  if use_gui = No then None
  else (
    match system#getenv "DISPLAY" with
    | None | Some "" ->
        if use_gui = Maybe then None
        else raise_safe "Can't use GUI because $DISPLAY is not set"
    | Some _ ->
        if !gui_plugin = None then (
          let bindir = Filename.dirname (U.realpath system config.abspath_0install) in

          let check_plugin_dir plugin_dir =
            let plugin_path = plugin_dir +/ "gui_gtk.cma" |> Dynlink.adapt_filename in
            log_info "Checking for GTK plugin at '%s'" plugin_path;
            if system#file_exists plugin_path then Some plugin_path else None in

          let plugin_path =
            let sys_lib = Filename.dirname bindir +/ "lib" in
            U.first_match check_plugin_dir [
              (* Is 0install is installed as distro package? *)
              sys_lib +/ "0install.net";
              (* Are we running via 0install? *)
              bindir;
            ] in

          match plugin_path with
          | None -> log_info "No GUI plugins found"
          | Some plugin_path ->
              try
                Dynlink.loadfile plugin_path;
              with
              | Dynlink.Error ex ->
                log_warning "Failed to load GTK GUI plugin: %s" (Dynlink.error_message ex)
              | ex ->
                log_warning ~ex "Failed to load GTK GUI plugin"
        );

        !gui_plugin |> pipe_some (fun gui_plugin ->
          try
            gui_plugin config use_gui
          with ex ->
            log_warning ~ex "Failed to create GTK GUI";
            None
        )
  )

let send_bug_report iface_uri message : string Lwt.t =
  let error_buffer = ref "" in
  try
    (* todo: Check the interface to decide where to send bug reports *)
    let url = "http://0install.net/api/report-bug/" in
    let connection = Curl.init () in
    Curl.set_nosignal connection true;    (* Can't use DNS timeouts when multi-threaded *)
    Curl.set_failonerror connection true;
    if Support.Logging.will_log Support.Logging.Debug then Curl.set_verbose connection true;

    Curl.set_errorbuffer connection error_buffer;

    let output_buffer = Buffer.create 256 in
    Curl.set_writefunction connection (fun data ->
      Buffer.add_string output_buffer data;
      String.length data
    );

    let post_data = Printf.sprintf "uri=%s&body=%s" (Curl.escape iface_uri) (Curl.escape message) in

    Curl.set_url connection url;
    Curl.set_post connection true;
    Curl.set_postfields connection post_data;
    Curl.set_postfieldsize connection (String.length post_data);

    Curl.perform connection;

    Lwt.return (Buffer.contents output_buffer)
  with Curl.CurlException _ as ex ->
    log_info ~ex "Curl error: %s" !error_buffer;
    raise_safe "Failed to submit bug report: %s\n%s" (Printexc.to_string ex) !error_buffer
