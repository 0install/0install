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

let string_of_ynm = function
  | Yes -> "yes"
  | No -> "no"
  | Maybe -> "maybe"

let get_impl (feed_provider:Feed_provider.feed_provider) sel =
  let {Feed.id; Feed.feed = from_feed} = Selections.get_id sel in

  let get_override overrides =
    try Some (StringMap.find id overrides.F.user_stability)
    with Not_found -> None in

  match Feed_cache.parse_feed_url from_feed with
  | `distribution_feed master_feed_url -> (
      let (`remote_feed master_feed_url | `local_feed master_feed_url) = master_feed_url in
      match feed_provider#get_feed master_feed_url with
      | None -> None
      | Some (master_feed, _) ->
          match feed_provider#get_distro_impls master_feed with
          | None -> None
          | Some (impls, overrides) ->
              let impl =
                try Some (List.find (fun impl -> F.get_attr_ex FeedAttr.id impl = id) impls)
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
  | [] -> Q.raise_elem "Implementation %s has no retrieval methods!" (F.get_attr_ex FeedAttr.id impl) impl.F.qdom
  | methods ->
      let size = U.first_match methods ~f:(fun m ->
        match Recipe.parse_retrieval_method m with
        | Some recipe -> Some (Recipe.get_download_size recipe)
        | None -> None
      ) in
      match size with
      | Some size -> size
      | None -> Q.raise_elem "Implementation %s has no usable retrieval methods!" (F.get_attr_ex FeedAttr.id impl) impl.F.qdom

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

let first_para text =
  let first =
    try
      let index = Str.search_forward (Str.regexp_string "\n\n") text 0 in
      String.sub text 0 index
    with Not_found -> text in
  Str.global_replace (Str.regexp_string "\n") " " first |> trim

(** Try to guess whether we have source for this interface.
 * Returns true if we have any source-only feeds, or any source implementations
 * in our regular feeds. However, we don't look inside the source feeds (so a
 * source feed containing no implementations will still count as true).
 * This is used in the GUI to decide whether to shade the Compile button.
 *)
let have_source_for feed_provider iface =
  let user_feeds = (feed_provider#get_iface_config iface).Feed_cache.extra_feeds in
  let imported =
    match feed_provider#get_feed iface with
    | None -> []
    | Some (feed, _overrides) -> feed.Feed.imported_feeds in

  let have_source = ref false in
  let to_check = ref [iface] in

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

let build_tree config (feed_provider:Feed_provider.feed_provider) old_sels sels : Yojson.Basic.json =
  let rec process_tree (uri, details) =
    let (name, summary, description, feed_imports) =
      match feed_provider#get_feed uri with
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
    let user_feeds = (feed_provider#get_iface_config uri).Feed_cache.extra_feeds in
    let all_feeds = uri :: (user_feeds @ feed_imports |> List.map (fun {F.feed_src; _} -> feed_src)) in

    let about_feed = [
      ("interface", `String uri);
      ("name", `String name);
      ("summary", `String summary);
      ("summary-tip", `String (default "(no description available)" description |> first_para));
      ("may-compile", `Bool (have_source_for feed_provider uri));
      ("all-feeds", `List (all_feeds |> List.map (fun s -> `String s)));
    ] in

    match details with
    | `Selected (sel, children) -> (
        match get_impl feed_provider sel with
        | None -> `Assoc (("type", `String "error") :: about_feed)
        | Some (impl, user_stability) ->
            let orig_sel =
              try Some (StringMap.find uri old_sels)
              with Not_found -> None in

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

            let {Feed.id; Feed.feed = from_feed} = Selections.get_id sel in

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
        let impl_id = F.get_attr_ex FeedAttr.id impl in
        let notes =
          match problem with
          | None -> "None"
          | Some problem -> Impl_provider.describe_problem impl problem in
        let from_feed = F.get_attr_ex FeedAttr.from_feed impl in
        let overrides = Feed.load_feed_overrides config from_feed in
        let user_stability =
          try `String (F.format_stability @@ StringMap.find impl_id overrides.F.user_stability)
          with Not_found -> `Null in
        let arch =
          match impl.F.os, impl.F.machine with
          | None, None -> "any"
          | os, machine -> Arch.format_arch os machine in
        let upstream_stability = F.get_attr_ex FeedAttr.stability impl in    (* (note: impl.stability is overall stability) *)
        let (impl_dir, fetch, tooltip) = get_fetch_info config impl in

        `Assoc [
          ("from-feed", `String from_feed);
          ("id", `String impl_id);
          ("version", `String (F.get_attr_ex FeedAttr.version impl));
          ("released", `String (default "-" @@ F.get_attr_opt FeedAttr.released impl.F.props.F.attrs));
          ("fetch", `String fetch);
          ("stability", `String upstream_stability);
          ("user-stability", user_stability);
          ("arch", `String arch);
          ("langs", `String (default "-" @@ F.get_attr_opt FeedAttr.langs impl.F.props.F.attrs));
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
        ("selected-feed", `String (F.get_attr_ex FeedAttr.from_feed selected_impl));
        ("selected-id", `String (F.get_attr_ex FeedAttr.id selected_impl));
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

let format_para para =
  para |> Str.split (Str.regexp_string "\n") |> List.map trim |> String.concat " "

let get_sigs config url =
  match Feed_cache.get_cached_feed_path config url with
  | None -> Lwt.return []
  | Some cache_path ->
      if config.system#file_exists cache_path then (
        let xml = U.read_file config.system cache_path in
        lwt sigs, warnings = Support.Gpg.verify config.system xml in
        if warnings <> "" then log_info "get_last_modified: %s" warnings;
        Lwt.return sigs
      ) else Lwt.return []

(** Download an icon for this feed and add it to the
    icon cache. If the feed has no icon do nothing. *)
let download_icon config (downloader:Downloader.downloader) feed_provider feed_url =
  log_debug "download_icon %s" feed_url;

  let system = config.system in

  let modification_time =
    match Feed_cache.get_cached_icon_path config feed_url with
    | None -> None
    | Some existing_icon ->
        match system#stat existing_icon with
        | None -> None
        | Some info -> Some info.Unix.st_mtime in
(*
        from email.utils import formatdate
        modification_time = formatdate(timeval = file_mtime, localtime = False, usegmt = True)
*)

  let icon_url =
    match feed_provider#get_feed feed_url with
    | None -> None
    | Some (feed, _) ->
        (* Find a suitable icon to download *)
        feed.F.root.Q.child_nodes |> U.first_match ~f:(fun child ->
          match ZI.tag child with
          | Some "icon" -> (
              match ZI.get_attribute_opt "type" child with
              | Some "image/png" -> ZI.get_attribute_opt "href" child
              | _ -> log_debug "Skipping non-PNG icon"; None
          )
          | _ -> None
        ) in

  match icon_url with
  | None -> log_info "No PNG icons found in %s" feed_url; Lwt.return `Null
  | Some href ->
      try_lwt
        match_lwt downloader#download ?modification_time ~hint:feed_url href with
        | `network_failure msg -> raise_safe "%s" msg
        | `aborted_by_user -> Lwt.return `Null
        | `tmpfile tmpfile ->
            try
              let icons_cache = Basedir.save_path system cache_icons config.basedirs.Basedir.cache in
              let icon_file = icons_cache +/ Escape.escape feed_url in
              system#with_open_in [Open_rdonly;Open_binary] 0 tmpfile (function ic ->
                system#atomic_write [Open_wronly;Open_binary] icon_file ~mode:0o644 (U.copy_channel ic)
              );
              system#unlink tmpfile;
              Lwt.return `Null
            with ex ->
              system#unlink tmpfile;
              raise ex
      with Downloader.Unmodified ->
        Lwt.return `Null

(** The formatted text for the details panel in the interface properties box. *)
let get_feed_description config feed_provider feed_url =
  let trust_db = new Trust.trust_db config in
  let output = ref [] in
  let style name fmt =
    let do_print msg = output := `List [`String name; `String msg] :: !output in
    Printf.ksprintf do_print fmt in
  let heading fmt = style "heading" fmt in
  let plain fmt = style "plain" fmt in

  lwt () =
    match feed_provider#get_feed feed_url with
    | None -> plain "Not yet downloaded."; Lwt.return ()
    | Some (feed, overrides) ->
        heading "%s" feed.F.name;
        plain " (%s)" (default "-" @@ F.get_summary config.langs feed);
        plain "\n%s\n" feed_url;

        let parsed_url =
          match Feed_cache.parse_feed_url feed_url with
          | `remote_feed _ | `local_feed _ as parsed -> parsed
          | `distribution_feed _ -> raise_safe "Distribution feeds shouldn't appear in the GUI!" in

        lwt sigs =
          match parsed_url with
          | `local_feed _ -> Lwt.return []
          | `remote_feed _ as parsed_url ->
              plain "\n";
              lwt sigs = get_sigs config parsed_url in
              if sigs <> [] then (
                let domain = Trust.domain_from_url parsed_url in
                match trust_db#oldest_trusted_sig domain sigs with
                | Some last_modified ->
                    plain "Last upstream change: %s\n" (U.format_time @@ Unix.localtime last_modified)
                | None -> ()
              );

              let () =
                match overrides.F.last_checked with
                | Some last_checked ->
                    plain "Last checked: %s\n" (U.format_time @@ Unix.localtime last_checked)
                | None -> () in

              let () =
                match Feed_cache.get_last_check_attempt config feed_url, overrides.F.last_checked with
                (* Don't bother reporting successful attempts *)
                | Some last_check_attempt, Some last_checked when last_check_attempt > last_checked ->
                    plain "Last check attempt: %s (failed or in progress)\n" (U.format_time @@ Unix.localtime last_check_attempt)
                | _ -> () in
              Lwt.return sigs in

        heading "\nDescription\n";

        let description =
          match F.get_description config.langs feed with
          | Some description ->
              Str.split (Str.regexp_string "\n\n") description |> List.map format_para |> String.concat "\n\n"
          | None -> "-" in

        plain "%s\n" description;

        let need_gap = ref true in
        ZI.iter_with_name feed.F.root "homepage" ~f:(fun homepage ->
          if !need_gap then (
            plain "\n";
            need_gap := false
          );
          plain "Homepage: ";
          style "link" "%s\n" homepage.Q.last_text_inside;
        );

        match parsed_url with
        | `local_feed _ -> Lwt.return ()
        | `remote_feed _ as parsed_url ->
            let domain = Trust.domain_from_url parsed_url in
            heading "\nSignatures\n";
            if sigs = [] then (
              plain "No signature information (old style feed or out-of-date cache)\n";
              Lwt.return ()
            ) else (
              let module G = Support.Gpg in
              sigs |> Lwt_list.iter_s (function
                | G.ValidSig {G.fingerprint; G.timestamp} ->
                    lwt name = G.get_key_name config.system fingerprint in
                    plain "Valid signature by '%s'\n- Dated: %s\n- Fingerprint: %s\n"
                            (default "<unknown>" name) (U.format_time @@ Unix.localtime timestamp) fingerprint;
                    if not (trust_db#is_trusted ~domain fingerprint) then (
                      plain "WARNING: This key is not in the trusted list (either you removed it, or you trust one of the other signatures)\n"
                    );
                    Lwt.return ()
                | other_sig -> plain "%s\n" (G.string_of_sig other_sig); Lwt.return ()
              )
            ) in
  `List (List.rev !output) |> Lwt.return

(** Download the archives. Called when the user clicks the 'Run' button. *)
let download_archives ~feed_provider driver = function
  | (false, _) -> raise_safe "Can't download archives; solve failed!"
  | (true, results) ->
      let sels = results#get_selections in
      match_lwt driver#download_selections ~include_packages:true ~feed_provider sels with
      | `success -> Lwt.return (`String "ok")
      | `aborted_by_user -> Lwt.return (`String "aborted-by-user")

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

let add_remote_feed driver iface (feed_url:[`remote_feed of feed_url])  =
  match_lwt driver#download_and_import_feed feed_url with
  | `aborted_by_user -> raise_safe "Aborted by user"
  | `success _ | `no_update -> add_feed driver#config iface feed_url; Lwt.return `Null

let remove_feed config iface feed_url =
  let iface_config = Feed_cache.load_iface_config config iface in
  let user_import = Feed.make_user_import feed_url in
  let extra_feeds = iface_config.Feed_cache.extra_feeds |> List.filter ((<>) user_import) in
  if iface_config.Feed_cache.extra_feeds = extra_feeds then (
    raise_safe "Can't remove '%s'; it is not a user-added feed of %s" (Feed_cache.format_feed_url feed_url) iface;
  ) else (
    Feed_cache.save_iface_config config iface {iface_config with Feed_cache.extra_feeds};
  )

let set_impl_stability config feed_provider feed_url id rating =
  let (_feed, overrides) = feed_provider#get_feed feed_url |? lazy (raise_safe "Feed '%s' not found!" feed_url) in
  let overrides = {
    overrides with F.user_stability =
      match rating with
      | None -> StringMap.remove id overrides.F.user_stability
      | Some rating -> StringMap.add id rating overrides.F.user_stability
  } in
  F.save_feed_overrides config feed_url overrides;
  Lwt.return `Null

(** Run [argv] and return its stdout on success.
 * On error, report both stdout and stderr. *)
let run_subprocess argv =
  log_info "Running %s" (Support.Logging.format_argv_for_logging (Array.to_list argv));
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
      let sels = Selections.to_latest_format root in
      let sel = sels |> Q.find (fun child ->
        ZI.tag child = Some "selection" && ZI.get_attribute FeedAttr.interface child = iface
      ) in
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
  Lwt.return `Null      (* The GUI will now recalculate *)

(** Run the GUI to choose and download a set of implementations
 * If [use_gui] is No; just returns `Dont_use_GUI.
 * If Maybe, uses the GUI if possible.
 * If Yes, uses the GUI or throws an exception.
 * [test_callback] is used if the user clicks on the test button in the bug report dialog.
 *)
let get_selections_gui (driver:Driver.driver) ?test_callback ?(systray=false) mode reqs ~refresh ~use_gui =
  let config = driver#config in
  let slave = driver#slave in
  let distro = driver#distro in
  let fetcher = driver#fetcher in
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
    let feed_provider = ref (new Feed_provider.feed_provider config distro) in

    let original_solve = Solver.solve_for config !feed_provider reqs in
    let original_selections =
      match original_solve with
      | (false, _) -> StringMap.empty
      | (true, results) -> Selections.make_selection_map results#get_selections in

    let results = ref original_solve in

    let watcher =
      object
        method update ((ready, new_results), new_fp) =
          feed_provider := new_fp;
          results := (ready, new_results);
          Python.async (fun () ->
            let sels = new_results#get_selections in
            let tree = build_tree config new_fp original_selections sels in
            slave#invoke_async ~xml:sels (`List [`String "gui-update-selections"; `Bool ready; tree]) ignore
          )

        method report feed_url msg =
          Python.async (fun () ->
            let msg = Printf.sprintf "Feed '%s': %s" feed_url msg in
            log_info "Sending error to GUI: %s" msg;
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
          | `Download_only | `Select_for_run -> download_archives ~feed_provider:!feed_provider driver !results
      )
      | json -> raise_safe "download-archives: invalid request: %s" (Yojson.Basic.to_string (`List json))
    );

    Python.register_handler "set-impl-stability" (function
      | [`String from_feed; `String id; `Null] ->
          set_impl_stability config !feed_provider from_feed id None
      | [`String from_feed; `String id; `String level] ->
          set_impl_stability config !feed_provider from_feed id (Some (F.parse_stability ~from_user:true level))
      | json -> raise_safe "get-feed-description: invalid request: %s" (Yojson.Basic.to_string (`List json))
    );

    Python.register_handler "get-feed-description" (function
      | [`String feed_url] -> get_feed_description config !feed_provider feed_url
      | json -> raise_safe "get-feed-description: invalid request: %s" (Yojson.Basic.to_string (`List json))
    );

    Python.register_handler "download-icon" (function
      | [`String feed_url] -> download_icon config fetcher#downloader !feed_provider feed_url
      | json -> raise_safe "download-icon: invalid request: %s" (Yojson.Basic.to_string (`List json))
    );

    Python.register_handler "gui-compile" (function
      | [`String iface; `Bool autocompile] -> compile config !feed_provider iface ~autocompile
      | json -> raise_safe "gui-compile: invalid request: %s" (Yojson.Basic.to_string (`List json))
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
          ("may-compile", `Bool (have_source_for !feed_provider uri)) ::
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

    (* Used by the add-feed dialog *)
    Python.register_handler "add-remote-feed" (function
      | [`String iface; `String feed] -> (
          match Feed_cache.parse_feed_url feed with
          | `distribution_feed _ | `local_feed _ -> raise_safe "Not a remote URL: '%s'" feed
          | `remote_feed _ as url -> add_remote_feed driver iface url
      )
      | json -> raise_safe "add-remote-feed: invalid request: %s" (Yojson.Basic.to_string (`List json))
    );

    Python.register_handler "add-local-feed" (function
      | [`String iface; `String path] -> (
          match Feed_cache.parse_feed_url path with
          | `local_feed _ as feed -> add_feed config iface feed; Lwt.return `Null
          | `remote_feed _ | `distribution_feed _ -> raise_safe "Not a local feed '%s'!" path
      )
      | json -> raise_safe "add-local-feed: invalid request: %s" (Yojson.Basic.to_string (`List json))
    );

    Python.register_handler "remove-feed" (function
      | [`String iface; `String url] ->
          Feed_cache.parse_non_distro_url url |> remove_feed config iface;
          Lwt.return `Null
      | json -> raise_safe "remove-feed: invalid request: %s" (Yojson.Basic.to_string (`List json))
    );

    Python.register_handler "run-test" (function
      | [] -> (
          match test_callback with
          | None -> raise_safe "Can't do a test run - no test callback registered (sorry)"
          | Some test_callback ->
              let (ready, results) = !results in
              if ready then (
                let sels = results#get_selections in
                match Selections.get_unavailable_selections config ~distro sels with
                | [] ->
                  lwt result = test_callback sels in
                  Lwt.return (`String result)
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
      let driver = new Driver.driver config fetcher distro slave in
      let (ready, results, _feed_provider) = driver#solve_with_downloads ~watcher reqs ~force ~update_local:true in
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
