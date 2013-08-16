(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Support for 0install apps *)

open General
open Support.Common

let re_app_name = Str.regexp "^[^./\\\\:=;'\"][^/\\\\:=;'\"]*$";;

let lookup_app config name =
  if Str.string_match re_app_name name 0 then
    let module Basedir = Support.Basedir in
    Basedir.load_first config.system ("0install.net" +/ "apps" +/ name) config.basedirs.Basedir.config
  else
    None
;;

exception Need_solve;;

let need_solve msg =
  log_info "Need to solve: %s" msg;
  raise Need_solve;;

(*
Ideally, this would return all the files which were inputs into the solver's
decision. Currently, we approximate with:
- the previously selected feed files (local or cached)
- configuration files for the selected interfaces
- the global configuration
We currently ignore feeds and interfaces which were
considered but not selected.
If this throws an exception, we will log it and re-solve anyway.
*)
let iter_inputs config cb sels =
  let check_maybe_config rel_path =
    match Config.load_first_config rel_path config with
    | None -> ()
    | Some p -> cb p
  in
  let check_sel sel_elem =
    let feed = Selections.get_feed sel_elem in

    (* Check per-feed config *)
    check_maybe_config (config_injector_interfaces +/ Escape.pretty feed);

    if Support.Utils.starts_with feed "distribution:" then
      (* If the package has changed version, we'll detect that below with get_unavailable_selections. *)
      ()
    else if Support.Utils.path_is_absolute feed then
      cb feed   (* Check the timestamp of this local feed hasn't changed *)
    else
      (* Remote feed *)
      match Feed_cache.get_cached_feed_path config feed with
      | None -> need_solve "Source feed no longer cached!"
      | Some path -> cb path              (* Check feed hasn't changed *)
  in
  ZI.iter_with_name ~f:check_sel sels "selection";

  (* Check global config *)
  check_maybe_config config_injector_global
;;


(** Get the mtime of the given path. If the path doesn't exist, returns 0.0 and,
    if [warn_if_missing] is true, logs the problem.
  *)
let get_mtime path ~warn_if_missing =
  try (Unix.stat path).Unix.st_mtime
  with Unix.Unix_error _ as ex ->
    let () = if warn_if_missing then log_warning ~ex "Failed to get time-stamp of %s" path else ()
    in 0.0

let set_mtime config path =
  if not config.dry_run then (
    let system = config.system in
    system#with_open_out [Open_wronly; Open_creat] 0o644 path ignore;
    (* In case file already exists *)
    system#set_mtime path @@ system#time ()
  )


(* Do any updates. The possible outcomes are:

  - The current selections seem fine:
    - It's time to check for updates => use current selections, update in the background
    - Otherwise => use current selections

  - The current selections are unusable => we re-solve and download any new selections (blocking)

  - The current selections are OK, but we can do better:
    - without downloading => switch to the new selections now
    - with downloading => use current selections, update in the background
*)
let check_for_updates config ~distro app_path sels =
  let last_solve_path = app_path +/ "last-solve" in
  let last_check_path = app_path +/ "last-check-attempt" in
  let last_check_time = get_mtime (app_path +/ "last-checked") ~warn_if_missing:true in
  let last_solve_time = max (get_mtime last_solve_path ~warn_if_missing:false)
                            last_check_time in
  let system = config.system in

  let verify_unchanged path =
    let mtime = get_mtime path ~warn_if_missing:false in
    if mtime = 0.0 || mtime > last_solve_time then
      need_solve (Printf.sprintf "File '%s' has changed since we last did a solve" path)
    else () in

  (* Do we have everything we need to run now? *)
  let unavailable_sels =
    Selections.get_unavailable_selections config ~distro sels <> [] in

  (* Should we do a quick solve before running?
     Checks whether the inputs to the current solution have changed. *)
  let need_solve = unavailable_sels ||
    try iter_inputs config verify_unchanged sels; false
    with Need_solve -> true in

  (* Is it time for a background update anyway? *)
  let want_bg_update =
    let staleness = system#time () -. last_check_time in
    log_info "Staleness of app %s is %.0f hours" app_path (staleness /. (60. *. 60.));
    match config.freshness with
    | Some freshness_threshold -> Int64.of_float staleness >= freshness_threshold
    | None -> false in    (* Updates disabled *)

  log_info "check_for_updates: need_solve = %b, want_bg_update = %b; unavailable_sels = %b" need_solve want_bg_update unavailable_sels;

  (* When we solve, we might also discover there are new things we could download and therefore
     do a background update anyway. *)

  if need_solve then (
    (* Delete last-solve timestamp to force a recalculation.
       This is useful when upgrading from an old format that the Python can still handle but we can't. *)
    if system#file_exists last_solve_path && not config.dry_run then
      system#unlink last_solve_path;
    (* When this is implemented, will need to add use_gui option like in the Python. *)
    raise Fallback_to_Python
  ) else if want_bg_update then (
    let last_check_attempt = get_mtime last_check_path ~warn_if_missing:false in
    if last_check_attempt +. 60. *. 60. > system#time () then (
      log_info "Tried to check within last hour; not trying again now";
    ) else (
      try
        let extra_flags = if !Support.Logging.threshold = Support.Logging.Debug then ["-v"] else [] in
        set_mtime config last_check_path;
        system#spawn_detach @@ [config.abspath_0install; "update"; "--background"] @ extra_flags @ ["--"; app_path]
      with ex -> log_warning ~ex "Error starting check for updates to %s" app_path
    );
    sels
  ) else sels
;;

(** If [distro] is [None] then we don't check for updates. *)
let get_selections_internal config ?distro app_path =
  let sels_path = app_path +/ "selections.xml" in
  if Sys.file_exists sels_path then
    let sels = Selections.load_selections config.system sels_path in
    match distro with
    | None -> sels
    | Some distro -> check_for_updates config ~distro app_path sels
  else
    if distro <> None then raise Fallback_to_Python
    else raise_safe "App selections missing! Expected: %s" sels_path

let list_app_names config =
  let apps = ref StringSet.empty in
  let system = config.system in
  let module Basedir = Support.Basedir in
  let scan_dir path =
    let check_app name =
      if Str.string_match re_app_name name 0 then
        apps := StringSet.add name !apps in
    match system#readdir (path +/ config_site +/ "apps") with
    | Problem _ -> ()
    | Success files -> Array.iter check_app files in
  List.iter scan_dir config.basedirs.Basedir.config;
  StringSet.elements !apps

let get_requirements (system:system) path =
  Requirements.load system (path +/ "requirements.json")

let get_interface (system:system) path =
  (get_requirements system path).Requirements.interface_uri

let get_selections_may_update config distro app_path = get_selections_internal config ~distro app_path
let get_selections_no_updates config app_path = get_selections_internal config app_path
