(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Selecting and downloading: common code for select/download/update/run *)

open Zeroinstall.General
open Support.Common
open Options
module Qdom = Support.Qdom
module Launcher = Zeroinstall.Launcher
module Apps = Zeroinstall.Apps
module Requirements = Zeroinstall.Requirements
module U = Support.Utils
module H = Zeroinstall.Helpers

type target =
  | App of (filepath * Requirements.requirements)
  | Interface
  | Selections of Qdom.element

let local_path_of_iface uri =
  let starts = U.starts_with uri in
  if starts "http://" || starts "https://'" then (
    None
  ) else (
    if Filename.is_relative uri then
      failwith ("Invalid interface URI: " ^ uri)
    else
      Some uri
  )

(* If uri is a relative path, convert to an absolute one.
    A "file:///foo" URI is converted to "/foo".
    An "alias:prog" URI expands to the URI in the 0alias script
    Otherwise, return it unmodified. *)
let canonical_iface_uri (system:system) arg =
  let starts = U.starts_with arg in
  if starts "http://" || starts "https://'" then (
    if not (String.contains_from arg (String.index arg '/' + 2) '/') then
      raise_safe "Missing / after hostname in URI '%s'" arg;
    arg
  ) else if starts "alias:" then (
    let alias = U.string_tail arg 6 in
    let path =
      if Filename.is_implicit alias then
        U.find_in_path_ex system alias
      else
        alias in

    match Launcher.parse_script system path with
    | Some (Launcher.AliasScript info) -> info.Launcher.uri
    | _ -> raise_safe "Not an alias script: '%s'" path
  ) else (
    let path = U.realpath system @@ if starts "file:///" then (
      U.string_tail arg 7
    ) else if starts "file:" then (
        if arg.[5] = '/' then
          raise_safe "Use file:///path for absolute paths, not %s" arg;
        U.string_tail arg 5
    ) else (
      arg
    ) in

    let is_alias () =
      if not (String.contains arg '/') then (
        match U.find_in_path system arg with
        | None -> false
        | Some path -> Launcher.is_alias_script system path
      ) else (
        false
      ) in

    if system#file_exists path then
      path
    else if is_alias () then
      raise_safe "Bad interface name '%s'.\n(hint: try 'alias:%s' instead)" arg arg
    else
      raise_safe "Bad interface name '%s'.\n(doesn't start with 'http:', and doesn't exist as a local file '%s' either)" arg path
  )

type output_style = Output_none | Output_XML | Output_human

type select_options = {
  mutable must_select : bool;
  mutable refresh : bool;
  mutable output : output_style;
}

(** Does this command-line argument refer to an app, URI or selections document?
    Parses the flags and combines that with the target to get
    the new requirements and flags. *)
let resolve_target config flags arg =
  match Apps.lookup_app config arg with
  | Some app ->
      let old_reqs = Apps.get_requirements config.system app in
      let reqs = Req_options.parse_update_options flags old_reqs in
      (App (app, old_reqs), reqs)
  | None ->
      let uri = canonical_iface_uri config.system arg in

      let is_interface () =
        let default_command = if List.mem `Source flags then "compile" else "run" in
        let reqs = Req_options.parse_options flags uri ~command:(Some default_command) in
        (Interface, reqs) in

      let is_selections sels =
        let iface_uri = ZI.get_attribute "interface" sels in
        let command = ZI.get_attribute_opt "command" sels in
        let reqs = Req_options.parse_options flags iface_uri ~command in
        (Selections sels, reqs) in

      match local_path_of_iface uri with
      | None -> is_interface ()
      | Some path ->
          let root = Support.Qdom.parse_file config.system path in
          match ZI.tag root with
          | None -> Support.Qdom.raise_elem "Not a 0install document (wrong namespace on root element): " root
          | Some "selections" -> is_selections root
          | Some "interface" | Some "feed" -> is_interface ()
          | Some x -> raise_safe "Unexpected root element <%s>" x

(** Update all the feeds needed to solve for these requirements in a background process. *)
let spawn_background_update config reqs =
  let extra_flags = if !Support.Logging.threshold = Support.Logging.Debug then ["-v"] else [] in
  let args = Req_options.to_options reqs in
  (* Note: [spawn_detach] sends stdout to /dev/null *)
  config.system#spawn_detach @@ [config.abspath_0install; "update"; "--console"] @ extra_flags @ args @ [reqs.Requirements.interface_uri]

(** Get selections for the requirements. Will switch to GUI mode if necessary.
    @param select_only 
    @param download_only wait for stale feeds, and display GUI button as Download, not Run
    @return the selections, or None if the user cancels (in which case, there is no need to alert the user again)
    *)
let get_selections options ~refresh ?test_callback reqs mode =
  let config = options.config in
  let driver = Lazy.force options.driver in

  let select_with_refresh refresh =
    (* This is the slow path: we need to download things before selecting *)
    H.solve_and_download_impls driver ?test_callback reqs mode ~refresh ~use_gui:options.gui in

  (* Check whether we can run immediately, without downloading anything. This requires
     - the user didn't ask to refresh or show the GUI
     - we can solve using the feeds we've already cached
     - we don't need to download any implementations
    If we can run immediately, we might still spawn a background process to check for updates. *)

  if refresh || options.gui = Yes then (
    select_with_refresh refresh
  ) else (
    let feed_provider = new Zeroinstall.Feed_cache.feed_provider config driver#distro in
    match Zeroinstall.Solver.solve_for config feed_provider reqs with
    | (false, _results) ->
        log_info "Quick solve failed; can't select without updating feeds";
        select_with_refresh true
    | (true, results) ->
        let sels = results#get_selections in
        if mode = `Select_only || Zeroinstall.Selections.get_unavailable_selections config ~distro:driver#distro sels = [] then (
          (* (in select mode, we only care that we've made a selection, not that we've cached the implementations) *)

          let have_stale_feeds = feed_provider#have_stale_feeds () in

          if mode = `Download_only && (have_stale_feeds && config.network_use <> Offline) then (
            (* Updating in the foreground for Download_only mode is a bit inconsistent. Maybe we
               should have a separate flag for this behaviour? *)
            select_with_refresh true
          ) else (
            if have_stale_feeds then (
              (* There are feeds we should update, but we can run without them. *)
              let want_background_update =
                if config.network_use = Offline then (
                  log_info "No doing background update because we are in off-line mode."; false
                ) else if options.config.dry_run then (
                  Zeroinstall.Dry_run.log "[dry-run] would check for updates in the background"; false
                ) else (
                  true
                ) in

              if want_background_update then (
                spawn_background_update options.config reqs
              )
            );
            Some sels
          )
        ) else (
          select_with_refresh true
        )
  )

(** Process the app/interface/selections argument [arg], either getting the current selections
    or solving to find new ones. Also, download the selected versions (unless [for_op] is Select_only).

    Removes ShowHuman, ShowXML, Refresh and all selection options (e.g. --version-for) from
    [options.extra_options]. Displays results as XML or human readable output, if appropriate.
    For human-readable output, we also display any changes compared to the previous selections.
    For apps with human-readable output, we tell the user to use "update" to save the changes
    if the requirements or selections changed (except for Select_for_update mode).
    Calls [exit 1] if the user aborts using the GUI. *)
let handle options flags arg ?test_callback for_op =
  let config = options.config in

  let select_opts = {
    must_select = (for_op = `Select_only) || options.gui = Yes;
    output = (
      match for_op with   (* Default output style *)
      | `Select_only -> Output_human
      | `Download_only -> Output_none
      | `Select_for_run -> Output_none
    );
    refresh = false;
  } in

  let flags =
    Support.Utils.filter_map flags ~f:(function
      | `ShowHuman -> select_opts.output <- Output_human; None
      | `ShowXML -> select_opts.output <- Output_XML; None
      | `Refresh -> select_opts.refresh <- true; select_opts.must_select <- true; None
      | #select_option as o -> Some o
    ) in

  let maybe_show_sels sels =
    match select_opts.output with
    | Output_none -> ()
    | Output_XML -> Show.show_xml sels
    | Output_human -> Show.show_human config sels in

  let do_select requirements =
    log_info "Getting new selections for %s" arg;
    let sels = get_selections options ~refresh:select_opts.refresh ?test_callback requirements for_op in
    match sels with
    | None -> exit 1    (* Aborted by user *)
    | Some sels -> sels
  in

  if flags <> [] then (
    select_opts.must_select <- true;
  );
  let result = resolve_target options.config flags arg in

  let get_app_sels path =
    Zeroinstall.Apps.get_selections_may_update (Lazy.force options.driver) ~use_gui:options.gui path in

  match result with
  | (App (path, old_reqs), reqs) when select_opts.output = Output_human ->
      (* note: pass use_gui here once we support foreground updates for apps in OCaml *)
      let old_sels = get_app_sels path in
      let new_sels = if select_opts.must_select then do_select reqs else old_sels in
      Show.show_restrictions config.system reqs;
      Show.show_human config new_sels;
      if Whatchanged.show_changes config.system old_sels new_sels || reqs <> old_reqs then
        U.print config.system "(note: use '0install update' instead to save the changes)";
      new_sels
  | (App (path, _old_reqs), reqs) ->
      let new_sels =
        if select_opts.must_select then do_select reqs else (
          (* note: pass use_gui here once we support foreground updates for apps in OCaml *)
          get_app_sels path
        ) in
      maybe_show_sels new_sels;
      new_sels
  | (Interface, reqs) ->
      let new_sels = do_select reqs in
      maybe_show_sels new_sels;
      new_sels
  | (Selections old_sels, reqs) ->
      let new_sels = if select_opts.must_select then do_select reqs else (
        if for_op = `Select_only then old_sels else (
          (* Download if missing. Ignore distribution packages, because the version probably won't match exactly. *)
          let driver = Lazy.force options.driver in
          let feed_provider = new Zeroinstall.Feed_cache.feed_provider config driver#distro in
          Zeroinstall.Helpers.download_selections ~feed_provider ~include_packages:false driver old_sels;
          old_sels
        )
      ) in
      maybe_show_sels new_sels;
      ignore @@ Whatchanged.show_changes config.system old_sels new_sels;
      new_sels
