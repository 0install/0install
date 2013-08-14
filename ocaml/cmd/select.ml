(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install select" command *)

open General
open Support.Common
open Options
module Qdom = Support.Qdom

let use_ocaml_solver =                (* TODO: just for testing *)
  try ignore @@ Sys.getenv "USE_OCAML_SOLVER"; true
  with Not_found -> false

type target = App of filepath | Interface of iface_uri | Selections of Qdom.element

let local_path_of_iface uri =
  let starts = Support.Utils.starts_with uri in
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
  let starts = Support.Utils.starts_with arg in
  if starts "http://" || starts "https://'" then (
    if not (String.contains_from arg (String.index arg '/' + 2) '/') then
      raise_safe "Missing / after hostname in URI '%s'" arg;
    arg
  ) else if starts "alias:" then (
    let alias = Support.Utils.string_tail arg 6 in
    let path =
      if Filename.is_implicit alias then
        Support.Utils.find_in_path_ex system alias
      else
        alias in

    match Alias.parse_script system path with
    | None -> raise_safe "Not an alias script: '%s'" path
    | Some info -> info.Alias.uri
  ) else (
    let path = Support.Utils.realpath system @@ if starts "file:///" then (
      Support.Utils.string_tail arg 7
    ) else if starts "file:" then (
        if arg.[5] = '/' then
          raise_safe "Use file:///path for absolute paths, not %s" arg;
        Support.Utils.string_tail arg 5
    ) else (
      arg
    ) in

    let is_alias () =
      if not (String.contains arg '/') then (
        match Support.Utils.find_in_path system arg with
        | None -> false
        | Some path -> Alias.is_alias_script system path
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

let resolve_target config arg =
  match Apps.lookup_app config arg with
  | Some app -> App app
  | None ->
      let uri = canonical_iface_uri config.system arg in
      match local_path_of_iface uri with
      | None -> Interface uri
      | Some path ->
          let root = Support.Qdom.parse_file config.system path in
          match ZI.tag root with
          | None -> Support.Qdom.raise_elem "Not a 0install document (wrong namespace on root element): " root
          | Some "selections" -> Selections root
          | Some "interface" | Some "feed" -> Interface uri
          | Some x -> raise_safe "Unexpected root element <%s>" x

type select_mode =
  | Select_only       (* only download feeds, not archives; display "Select" in GUI *)
  | Download_only     (* download archives too; refresh if stale feeds; display "Download" in GUI *)
  | Select_for_run    (* download archives; update stale in background; display "Run" in GUI *)

(** Get selections for the requirements. Will switch to GUI mode if necessary.
    @param select_only 
    @param download_only wait for stale feeds, and display GUI button as Download, not Run
    @return the selections, or None if the user cancels (in which case, there is no need to alert the user again)
    *)
let get_selections options ~refresh reqs mode =
  let config = options.config in
  let action = match mode with
  | Select_only -> "select"
  | Download_only -> "download"
  | Select_for_run -> failwith "TODO: Select_for_run" in    (* TODO *)

  let select_with_refresh () =
    (* This is the slow path: we need to download things before selecting *)
    let read_xml s = Qdom.parse_input None @@ Xmlm.make_input (`String (0, s)) in
    let args = Requirements.to_options reqs @ ["--xml"; "--"; reqs.Requirements.interface_uri] in
    let args = if refresh then "--refresh" :: args else args in
    (* Note: parse the output only if it returns success *)
    let xml = read_xml @@ Python.check_output_python options Support.Utils.input_all action @@ args in
    if xml.Qdom.tag = ("", "cancelled") then
      None
    else
      Some xml in

  (* Check whether we can run immediately, without downloading anything. This requires
     - the user didn't ask to refresh or show the GUI
     - we can solve using the feeds we've already cached
     - we don't need to download any implementations
    If we can run immediately, we might still spawn a background process to check for updates. *)

  if refresh || options.gui = Yes then (
    select_with_refresh ()
  ) else (
    let distro = Lazy.force options.distro in
    try
      let feed_provider = new Feed_cache.feed_provider config distro in
      match Solver.solve_for config feed_provider reqs with
      | (false, results) ->
          if use_ocaml_solver then (
            print_endline "Quick solve failed (stopped for debugging):";
            Show.show_human config (results#get_selections ());
            None
          ) else (
            select_with_refresh()
          )
      | (true, results) ->
          let sels = results#get_selections () in
          if mode = Select_only || Selections.get_unavailable_selections config ~distro sels = [] then (
            (* (in select mode, we only care that we've made a selection, not that we've cached the implementations) *)

            let have_stale_feeds = feed_provider#have_stale_feeds () in

            if mode = Download_only && have_stale_feeds then (
              (* Updating in the foreground for Download_only mode is a bit inconsistent. Maybe we
                 should have a separate flag for this behaviour? *)
              select_with_refresh ()
            ) else (
              if have_stale_feeds then (
                (* There are feeds we should update, but we can run without them. *)
                let want_background_update =
                  if config.network_use = Offline then (
                    log_info "No doing background update because we are in off-line mode."; false
                  ) else if options.config.dry_run then (
                    Dry_run.log "[dry-run] would check for updates in the background"; false
                  ) else (
                    true
                  ) in

                if want_background_update then (
                  log_info "FIXME: Background update needed!";        (* TODO: spawn a background update instead *)
                  if not use_ocaml_solver then raise Fallback_to_Python
                )
              );
              Some sels
            )
          ) else (
            select_with_refresh ()
          )
    with Fallback_to_Python ->
      log_info "Can't solve; falling back to Python";
      select_with_refresh ()
  )

type select_options = {
  mutable xml : bool;
  mutable refresh : bool;
}

let handle options args =
  let config = options.config in

  let do_selections extra_options ?app_old_sels reqs ~changes =
    let select_opts = {
      xml = false;
      refresh = false;
    } in
    Support.Argparse.iter_options extra_options (function
      | ShowXML -> select_opts.xml <- true
      | Refresh -> select_opts.refresh <- true
      | _ -> raise_safe "Unknown option"
    );

    let sels = get_selections options ~refresh:select_opts.refresh reqs Select_only in

    match sels with
    | None -> exit 1    (* Aborted by user *)
    | Some sels ->
        if select_opts.xml then (
          Show.show_xml sels
        ) else (
          if app_old_sels <> None then
            Show.show_restrictions config.system reqs;
          Show.show_human config sels;
          match app_old_sels with
          | None -> ()
          | Some old_sels ->
            if Whatchanged.show_changes config.system old_sels sels || changes then
              Support.Utils.print config.system "(note: use '0install update' instead to save the changes)"
        )
  in

  match args with
  | [arg] -> (
    match resolve_target config arg with
    | App path ->
        let old_sels = Apps.get_selections_no_updates config path in
        let old_reqs = Apps.get_requirements config.system path in
        let (options, reqs) = Requirements.parse_update_options options.extra_options old_reqs in

        do_selections options reqs ~changes:(old_reqs <> reqs) ~app_old_sels:old_sels
    | Interface iface_uri ->
        let (options, reqs) = Requirements.parse_options options.extra_options iface_uri ~command:(Some "run") in
        do_selections options reqs ~changes:false
    | Selections root ->
        let iface_uri = ZI.get_attribute "interface" root in
        let command = ZI.get_attribute_opt "command" root in
        let (options, reqs) = Requirements.parse_options options.extra_options iface_uri ~command in
        do_selections options reqs ~changes:false
  )
  | _ -> raise Support.Argparse.Usage_error
