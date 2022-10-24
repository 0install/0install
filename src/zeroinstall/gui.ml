(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Manage the GUI sub-process. *)

open General
open Support
open Support.Common

module FeedAttr = Constants.FeedAttr
module F = Feed
module U = Support.Utils
module Q = Support.Qdom
module G = Support.Gpg

type feed_description = {
  times : (string * float) list;
  summary : string option;
  description : string list;
  homepages : string list;
  signatures : [
    | `Valid of G.fingerprint * G.timestamp * string option * [`Trusted | `Not_trusted]
    | `Invalid of string
  ] list;
}

let gui_plugin = ref None

let register_plugin fn =
  gui_plugin := Some fn

let get_download_size info impl =
  match info.Impl.retrieval_methods with
  | [] -> log_info "Implementation %s has no retrieval methods!" (Impl.get_attr_ex FeedAttr.id impl); None
  | methods ->
      methods |> U.first_match (fun m ->
        match Recipe.parse_retrieval_method m with
        | Some recipe -> Some (Recipe.get_download_size recipe)
        | None -> log_info "Implementation %s has no usable retrieval methods!" (Impl.get_attr_ex FeedAttr.id impl); None
      )

let get_fetch_info config impl =
  try
    match impl.Impl.impl_type with
    | `Binary_of _ -> ("(compile)", "Need to compile from source")
    | `Local_impl path -> ("(local)", path)
    | `Cache_impl info -> (
        match Stores.lookup_maybe config.system info.Impl.digests config.stores with
        | None ->
          begin match get_download_size info impl with
          | Some size ->
              let pretty = U.format_size size in
              (pretty, Printf.sprintf "Need to download %s (%s bytes)" pretty (Int64.to_string size))
          | None -> ("-", "No size") end;
        | Some path -> ("(cached)", "This version is already stored on your computer:\n" ^ path)
    )
    | `Package_impl info ->
        begin match info.Impl.package_state with
        | `Installed -> ("(package)", "This distribution-provided package is already installed.")
        | `Uninstalled retrieval_method ->
          let size = retrieval_method.Impl.distro_size |> pipe_some (fun s -> Some (Int64.to_float s)) in
          match size with
          | None -> ("(install)", "No size information available for this download")
          | Some size ->
              let pretty = U.format_size (Int64.of_float size) in
              (pretty, Printf.sprintf "Distribution package: need to download %s (%s bytes)" pretty (string_of_float size))
        end
  with Safe_exn.T e as ex ->
    log_warning ~ex "get_fetch_info";
    ("ERROR", Safe_exn.msg e)

let have_source_for feed_provider iface =
  let master_feed = Feed_url.master_feed_of_iface iface in
  let user_feeds = (feed_provider#get_iface_config iface).Feed_cache.extra_feeds in
  let imported =
    match feed_provider#get_feed master_feed with
    | None -> []
    | Some (feed, _overrides) -> Feed.imported_feeds feed in

  let have_source = ref false in
  let to_check = ref [master_feed] in

  (user_feeds @ imported) |> List.iter (fun feed_import ->
    match feed_import.Feed_import.machine with
    | x when Arch.is_src x -> have_source := true   (* Source-only feed *)
    | Some _ -> ()    (* Binary-only feed; can't contain source *)
    | None -> to_check := feed_import.Feed_import.src :: !to_check (* Mixed *)
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
        Feed.zi_implementations feed |> XString.Map.exists (fun _id impl -> Impl.is_source impl)
    )
  )

let list_impls results role =
  let {Solver.iface; source; scope = _} = role in
  let impl_provider = Solver.impl_provider role in
  let selected_impl = Solver.Output.get_selected role results |> map_some Solver.Output.unwrap in
  let candidates = impl_provider#get_implementations iface ~source in

  let by_version (a,_) (b,_) = compare b.Impl.parsed_version a.Impl.parsed_version in

  let open Impl_provider in
  let good_impls = List.map (fun i -> (i, None)) candidates.impls in
  let bad_impls = List.map (fun (i, prob) -> (i, Some prob)) candidates.rejects in
  let all_impls = List.sort by_version @@ good_impls @ bad_impls in

  (selected_impl, all_impls)

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
        F.icons feed |> U.first_match (fun child ->
          match Element.icon_type child with
          | Some "image/png" -> Some (Element.href child)
          | _ -> log_debug "Skipping non-PNG icon"; None
        ) in

  match icon_url with
  | None -> log_info "No PNG icons found in %s" feed_url; Lwt.return ()
  | Some href ->
      fetcher#download_icon parsed_url href

let add_feed config iface feed_url =
  let (`Remote_feed url | `Local_feed url) = feed_url in

  let feed = Feed_cache.get_cached_feed config feed_url |? lazy (Safe_exn.failf "Failed to read new feed!") in
  match Feed.get_feed_targets feed with
  | [] -> Safe_exn.failf "Feed '%s' is not a feed for '%s'" url iface
  | feed_for when List.mem iface feed_for ->
      let user_import = Feed_import.make_user feed_url in
      let iface_config = Feed_cache.load_iface_config config iface in

      let extra_feeds = iface_config.Feed_cache.extra_feeds in
      if List.mem user_import extra_feeds then (
        Safe_exn.failf "Feed from '%s' has already been added!" url
      ) else (
        let extra_feeds = user_import :: extra_feeds in
        Feed_cache.save_iface_config config iface {iface_config with Feed_cache.extra_feeds};
      );
  | feed_for -> Safe_exn.failf "This is not a feed for '%s'.\nOnly for:\n%s" iface (String.concat "\n" feed_for)

let add_remote_feed config fetcher iface (feed_url:[`Remote_feed of Sigs.feed_url]) =
  Driver.download_and_import_feed fetcher feed_url >>= function
  | `Aborted_by_user -> Lwt.return ()
  | `Success _ | `No_update -> add_feed config iface feed_url; Lwt.return ()

let remove_feed config iface feed_url =
  let iface_config = Feed_cache.load_iface_config config iface in
  let user_import = Feed_import.make_user feed_url in
  let extra_feeds = iface_config.Feed_cache.extra_feeds |> List.filter ((<>) user_import) in
  if iface_config.Feed_cache.extra_feeds = extra_feeds then (
    Safe_exn.failf "Can't remove '%s'; it is not a user-added feed of %s" (Feed_url.format_url feed_url) iface;
  ) else (
    Feed_cache.save_iface_config config iface {iface_config with Feed_cache.extra_feeds};
  )

(** Run [argv] and return its stdout on success.
 * On error, report both stdout and stderr. *)
let run_subprocess argv =
  log_info "Running %s" (Support.Logging.format_argv_for_logging (Array.to_list argv));
  Safe_exn.with_info
    (fun f -> f "... executing %s" (Support.Logging.format_argv_for_logging (Array.to_list argv)))
    (fun () ->
      let command = (argv.(0), argv) in
      let child = Lwt_process.open_process_full command in
      Lwt_io.close child#stdin >>= fun () ->
      let stdout = Lwt_io.read child#stdout
      and stderr = Lwt_io.read child#stderr in
      stdout >>= fun stdout ->
      stderr >>= fun stderr ->
      child#close >>= function
      | Unix.WEXITED 0 -> Lwt.return stdout
      | status ->
          let output = stdout ^ stderr in
          if output = "" then Support.System.check_exit_status status;
          Safe_exn.failf "Compile failed: %s" output
    )

let build_and_register config iface min_0compile_version =
  run_subprocess [|
    config.abspath_0install; "run";
    "--message"; "Download the 0compile tool, to compile the source code";
    "--not-before=" ^ (Version.to_string min_0compile_version);
    "http://0install.net/2006/interfaces/0compile.xml";
    "gui";
    iface
  |] >|= ignore

(* Running subprocesses is a bit messy; this is just a direct translation of the (old) Python code. *)
let compile config feed_provider iface ~autocompile =
  let our_min_version = Version.parse "1.0" in     (* The oldest version of 0compile we support *)

  if autocompile then (
    run_subprocess [|
      config.abspath_0install; "run";
      "--message"; "Download the 0compile tool to compile the source code";
      "--not-before=" ^ (Version.to_string our_min_version);
      "http://0install.net/2006/interfaces/0compile.xml";
      "autocompile";
      "--gui";
      "--"; iface;
    |] >|= ignore
  ) else (
    (* Prompt user to choose source version *)
    run_subprocess [|
      config.abspath_0install; "download"; "--xml";
      "--message"; "Download the source code to be compiled";
      "--gui"; "--source";
      "--"; iface;
    |] >>= fun stdout ->
    let root = `String (0, stdout) |> Xmlm.make_input |> Q.parse_input None in
    let sels = Selections.create root in
    let sel = Selections.get_selected {Selections.iface; source = true} sels in
    let sel = sel |? lazy (Safe_exn.failf "No implementation of root (%s)!" iface) in
    let min_version =
      match Element.compile_min_version sel with
      | None -> our_min_version
      | Some min_version -> max our_min_version (Version.parse min_version) in
    build_and_register config iface min_version
  ) >>= fun () ->

  (* A new local feed may have been registered, so reload it from the disk cache *)
  log_info "0compile command completed successfully. Reloading interface details.";
  feed_provider#forget_user_feeds iface;
  Lwt.return ()      (* The plugin should now recalculate *)

let get_bug_report_details config ~role (ready, results) =
  let system = config.system in
  let sels = Solver.selections results in
  let root_role = Solver.Output.((requirements results).role) in
  let issue_file = "/etc/issue" in
  let issue =
    if system#file_exists issue_file then
      U.read_file system issue_file |> String.trim
    else
      Printf.sprintf "(file '%s' not found)" issue_file in

  let b = Buffer.create 1000 in
  let add fmt =
    let do_add msg = Buffer.add_string b msg in
    Format.kasprintf do_add fmt in

  add "Problem with %a\n" Solver.Output.Role.pp role;
  if role <> root_role then
    add "  (while attempting to run %a)\n" Solver.Output.Role.pp root_role;
  add "\n";

  add "0install version %s\n" About.version;

  if ready then (
    let f = Format.formatter_of_buffer b in
    Tree.print config f sels;
    Format.pp_print_newline f ()
  ) else (
    Buffer.add_string b @@ Solver.get_failure_reason config results
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
  Lwt.catch
    (fun () ->
      if ready then (
        let sels = Solver.selections results in
        match Driver.get_unavailable_selections config ~distro sels with
        | [] -> test_callback sels
        | missing ->
            let details =
              missing |> List.map (fun sel ->
                Printf.sprintf "%s version %s\n  (%s)"
                  (Element.interface sel)
                  (Element.version sel)
                  (Element.id sel)
              ) |> String.concat "\n\n- " in
            Safe_exn.failf "Can't run: the chosen versions have not been downloaded yet. I need:\n\n- %s" details
      ) else Safe_exn.failf "Can't do a test run - solve failed"
    )
    (fun ex -> Lwt.return (Printexc.to_string ex))

let try_get_gui config ~use_gui =
  let system = config.system in
  match use_gui with
  | `No -> None
  | `Yes | `Auto as use_gui ->
    match system#getenv "DISPLAY" with
    | None | Some "" ->
        if use_gui = `Auto then None
        else Safe_exn.failf "Can't use GUI because $DISPLAY is not set"
    | Some _ ->
        if !gui_plugin = None then (
          let bindir = Filename.dirname (U.realpath system config.abspath_0install) in

          let check_plugin_dir plugin_dir =
            let plugin_path = plugin_dir +/ "gui_gtk.cmxs" in
            log_info "Checking for GTK plugin at '%s'" plugin_path;
            if system#file_exists plugin_path then Some plugin_path else None in

          let plugin_path =
            let sys_lib = Filename.dirname bindir +/ "lib" in
            U.first_match check_plugin_dir [
              (* Was 0install installed with opam? *)
              sys_lib +/ "0install-gtk";
              (* Is 0install is installed as distro package? *)
              sys_lib +/ "0install.net";
              (* Are we running via 0install? *)
              bindir +/ "gui_gtk";
            ] in

          match plugin_path with
          | None -> log_info "No GUI plugins found"
          | Some plugin_path ->
              try
                Dynlink.allow_unsafe_modules true;
                Dynlink.loadfile plugin_path;
              with
              | Dynlink.Error ex ->
                log_warning "Failed to load GTK GUI plugin: %s" (Dynlink.error_message ex)
              | ex ->
                log_warning ~ex "Failed to load GTK GUI plugin"
        );

        match !gui_plugin with
        | None ->
            if use_gui = `Auto then None
            else Safe_exn.failf "Can't use GUI - plugin cannot be loaded"
        | Some gui_plugin ->
            try
              gui_plugin config
            with ex ->
              log_warning ~ex "Failed to create GTK GUI";
              None

let send_bug_report iface_uri message : string Lwt.t =
  (* todo: Check the interface to decide where to send bug reports *)
  let url = "http://api.0install.net/api/report-bug/" in
  let data = Printf.sprintf "uri=%s&body=%s" (Http.escape iface_uri) (Http.escape message) in
  Http.post ~data url >|= function
  | Ok data -> data
  | Error (msg, data) ->
    Safe_exn.failf "Failed to submit bug report: %s\n%s" msg data

let get_sigs config url =
  match Feed_cache.get_cached_feed_path config url with
  | None -> Lwt.return []
  | Some cache_path ->
      if config.system#file_exists cache_path then (
        let xml = U.read_file config.system cache_path in
        let gpg = Support.Gpg.make config.system in
        Support.Gpg.verify gpg xml >|= fun (sigs, warnings) ->
        if warnings <> "" then log_info "get_last_modified: %s" warnings;
        sigs
      ) else Lwt.return []

let format_para para =
  para |> Str.split (Str.regexp_string "\n") |> List.map String.trim |> String.concat " "

(** The formatted text for the details panel. *)
let generate_feed_description config trust_db feed overrides =
  let times = ref [] in

  begin match F.url feed with
  | `Local_feed _ -> Lwt.return []
  | `Remote_feed _ as feed_url ->
      let domain = Trust.domain_from_url feed_url in
      get_sigs config feed_url >>= fun sigs ->
      if sigs <> [] then (
        match trust_db#oldest_trusted_sig domain sigs with
        | Some last_modified -> times := ("Last upstream change", last_modified) :: !times
        | None -> ()
      );

      overrides.Feed_metadata.last_checked |> if_some (fun last_checked ->
        times := ("Last checked", last_checked) :: !times
      );

      Feed_cache.get_last_check_attempt config feed_url |> if_some (fun last_check_attempt ->
        match overrides.Feed_metadata.last_checked with
        | Some last_checked when last_check_attempt <= last_checked ->
            () (* Don't bother reporting successful attempts *)
        | _ ->
            times := ("Last check attempt (failed or in progress)", last_check_attempt) :: !times
      );

      sigs |> Lwt_list.map_s (function
        | G.ValidSig {G.fingerprint; G.timestamp} ->
            let gpg = G.make config.system in
            G.get_key_name gpg fingerprint >|= fun name ->
            let is_trusted =
              if trust_db#is_trusted ~domain fingerprint then `Trusted else `Not_trusted in
            `Valid (fingerprint, timestamp, name, is_trusted)
        | other_sig ->
            `Invalid (G.string_of_sig other_sig) |> Lwt.return
      )
  end >>= fun signatures ->

  let description =
    match F.get_description config.langs feed with
    | Some description -> Str.split (Str.regexp_string "\n\n") description |> List.map format_para
    | None -> ["-"] in

  let homepages = Feed.root feed |> Element.feed_metadata |> List.filter_map (function
    | `Homepage homepage -> Some (Element.simple_content homepage)
    | _ -> None
  ) in

  Lwt.return {
    times = List.rev !times;
    summary = F.get_summary config.langs feed;
    description;
    homepages;
    signatures;
  }
