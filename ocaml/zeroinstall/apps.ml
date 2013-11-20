(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Support for 0install apps *)

open General
open Support.Common
module Basedir = Support.Basedir
module U = Support.Utils

let re_app_name = Str.regexp "^[^./\\\\:=;'\"][^/\\\\:=;'\"]*$"

let validate_name purpose name =
  if name = "0install" then
    raise_safe "Creating an %s called '0install' would cause trouble; try e.g. '00install' instead" purpose;
  if not @@ Str.string_match re_app_name name 0 then
    raise_safe "Invalid %s name '%s'" purpose name

let lookup_app config name =
  if Str.string_match re_app_name name 0 then
    Basedir.load_first config.system ("0install.net" +/ "apps" +/ name) config.basedirs.Basedir.config
  else
    None

exception Need_solve

let need_solve msg =
  log_info "Need to solve: %s" msg;
  raise Need_solve

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

    match Feed_url.parse feed with
      (* If the package has changed version, we'll detect that below with get_unavailable_selections. *)
    | `distribution_feed _ -> ()
    | `local_feed path -> cb path   (* Check the timestamp of this local feed hasn't changed *)
    | `remote_feed _ as remote_feed ->
      match Feed_cache.get_cached_feed_path config remote_feed with
      | None -> need_solve @@ "Source feed no longer cached: " ^ feed
      | Some path -> cb path              (* Check feed hasn't changed *)
  in
  ZI.iter check_sel sels ~name:"selection";

  (* Check global config *)
  check_maybe_config config_injector_global

(** Get the mtime of the given path. If the path doesn't exist, returns 0.0 and,
    if [warn_if_missing] is true, logs the problem.
  *)
let get_mtime system path ~warn_if_missing =
  match system#stat path with
  | Some info -> info.Unix.st_mtime
  | None ->
      if warn_if_missing then log_warning "Missing time-stamp file '%s'" path;
      0.0

let set_mtime config path =
  if not config.dry_run then (
    let system = config.system in
    system#with_open_out [Open_wronly; Open_creat] 0o644 path ignore;
    (* In case file already exists *)
    system#set_mtime path @@ system#time
  )

let get_requirements (system:system) path =
  Requirements.load system (path +/ "requirements.json")

let get_interface (system:system) path =
  (get_requirements system path).Requirements.interface_uri

let set_last_checked system app_dir =
  U.touch system @@ app_dir +/ "last-checked"

let set_selections config app_path sels ~touch_last_checked =
  let date = U.format_date (Unix.gmtime @@ config.system#time) in
  let sels_file = app_path +/ (Printf.sprintf "selections-%s.xml" date) in

  Support.Qdom.reindent sels;

  if config.dry_run then
    Dry_run.log "would write selections to %s" sels_file
  else (
    config.system#atomic_write [Open_wronly;Open_binary] sels_file ~mode:0o644 (fun ch ->
      Support.Qdom.output (Xmlm.make_output @@ `Channel ch) sels
    )
  );

  let sels_latest = app_path +/ "selections.xml" in
  if config.dry_run then
    Dry_run.log "would update %s to point to new selections file" sels_latest
  else (
    U.atomic_hardlink config.system ~link_to:sels_file ~replace:sels_latest
  );

  if touch_last_checked && not config.dry_run then
    set_last_checked config.system app_path

(* We can't run with saved selections or solved selections without downloading.
   Try to open the GUI for a blocking download. If we can't do that, download without the GUI. *)
let foreground_update driver app_path reqs =
  log_info "App '%s' needs to get new selections; current ones are not usable" app_path;
  match Helpers.solve_and_download_impls driver reqs `Download_only ~refresh:true with
  | None -> raise_safe "Aborted by user"
  | Some sels ->
      set_selections driver#config app_path sels ~touch_last_checked:true;
      sels

type app_times = {
  last_check_time : float;              (* 0.0 => timestamp missing *)
  last_check_attempt : float option;    (* always > last_check_time, if present *)
  last_solve : float;                   (* 0.0 => timestamp missing *)
}

let get_times system app =
  let last_check_attempt = get_mtime system (app +/ "last-check-attempt") ~warn_if_missing:false in
  let last_check_time = get_mtime system (app +/ "last-checked") ~warn_if_missing:true in {
    last_check_time;
    last_check_attempt = if last_check_attempt > last_check_time then Some last_check_attempt else None;
    last_solve = get_mtime system (app +/ "last-solve") ~warn_if_missing:false;
  }

(* Do any updates. The possible outcomes are:

  - The current selections seem fine:
    - It's time to check for updates => use current selections, update in the background
    - Otherwise => use current selections

  - The current selections are unusable => we re-solve and download any new selections (blocking)

  - The current selections are OK, but we can do better:
    - without downloading => switch to the new selections now
    - with downloading => use current selections, update in the background
*)
let check_for_updates driver app_path sels =
  let config = driver#config in
  let system = config.system in
  let last_solve_path = app_path +/ "last-solve" in
  let last_check_path = app_path +/ "last-check-attempt" in
  let last_check_time = get_mtime system (app_path +/ "last-checked") ~warn_if_missing:true in
  let last_solve_time = max (get_mtime system last_solve_path ~warn_if_missing:false)
                            last_check_time in

  let verify_unchanged path =
    let mtime = get_mtime system path ~warn_if_missing:false in
    if mtime = 0.0 || mtime > last_solve_time then
      need_solve (Printf.sprintf "File '%s' has changed since we last did a solve" path)
    else () in

  (* Do we have everything we need to run now? *)
  let unavailable_sels =
    Selections.get_unavailable_selections config ~distro:driver#distro sels <> [] in

  (* Should we do a quick solve before running?
     Checks whether the inputs to the current solution have changed. *)
  let need_solve = unavailable_sels ||
    try iter_inputs config verify_unchanged sels; false
    with Need_solve -> true in

  (* Is it time for a background update anyway? *)
  let want_bg_update = ref (
    let staleness = system#time -. last_check_time in
    log_info "Staleness of app %s is %.0f hours" app_path (staleness /. (60. *. 60.));
    match config.freshness with
    | Some freshness_threshold -> staleness >= freshness_threshold
    | None -> false     (* Updates disabled *)
  ) in

  log_info "check_for_updates: need_solve = %b, want_bg_update = %b; unavailable_sels = %b" need_solve !want_bg_update unavailable_sels;

  (* When we solve, we might also discover there are new things we could download and therefore
     do a background update anyway. *)

  let sels =
    if need_solve then (
      let reqs = get_requirements system app_path in
      let new_sels =
        match driver#quick_solve reqs with
        | Some new_sels ->
            if Support.Qdom.compare_nodes ~ignore_whitespace:true new_sels sels = 0 then (
              log_info "Quick solve succeeded; no change needed";
              sels
            ) else (
              log_info "Quick solve succeeded; saving new selections";
              set_selections config app_path new_sels ~touch_last_checked:false;
              new_sels
            );
        | None ->
            log_info "Quick solve failed; we need to download something";
            if unavailable_sels then (
              (* Delete last-solve timestamp to force a recalculation.
                 This is useful when upgrading from an old format that the Python can still handle but we can't. *)
              if system#file_exists last_solve_path && not config.dry_run then
                system#unlink last_solve_path;

              foreground_update driver app_path reqs
            ) else (
              (* Continue with the current (cached) selections while we download *)
              want_bg_update := true;
              sels
            ) in
      let () =
        try U.touch system (app_path +/ "last-solve");
        with ex -> log_warning ~ex "Error while checking for updates" in
      new_sels
    ) else sels in

  if !want_bg_update then (
    let last_check_attempt = get_mtime system last_check_path ~warn_if_missing:false in
    if last_check_attempt +. 60. *. 60. > system#time then (
      log_info "Tried to check within last hour; not trying again now";
    ) else (
      try
        let extra_flags = if Support.Logging.will_log Support.Logging.Debug then ["-v"] else [] in
        set_mtime config last_check_path;
        system#spawn_detach @@ [config.abspath_0install; "update-bg"] @ extra_flags @ ["--"; "app"; app_path]
      with ex -> log_warning ~ex "Error starting background check for updates to %s" app_path
    );
    sels
  ) else sels

(** If [driver] is [None] then we don't check for updates. *)
let get_selections_internal system ?driver app_path =
  let sels_path = app_path +/ "selections.xml" in
  if Sys.file_exists sels_path then
    let sels = Selections.load_selections system sels_path in
    match driver with
    | None -> sels
    | Some driver -> check_for_updates driver app_path sels
  else
    match driver with
    | Some driver -> foreground_update driver app_path (get_requirements system app_path)
    | None -> raise_safe "App selections missing! Expected: %s" sels_path

let list_app_names config =
  let apps = ref StringSet.empty in
  let system = config.system in
  let scan_dir path =
    let check_app name =
      if Str.string_match re_app_name name 0 then
        apps := StringSet.add name !apps in
    match system#readdir (path +/ config_site +/ "apps") with
    | Problem _ -> ()
    | Success files -> Array.iter check_app files in
  List.iter scan_dir config.basedirs.Basedir.config;
  StringSet.elements !apps

let get_selections_may_update driver app_path =
  get_selections_internal driver#config.system ~driver app_path

let get_selections_no_updates config app_path = get_selections_internal config app_path

let set_requirements config path req =
  let reqs_file = path +/ "requirements.json" in
  if config.dry_run then
    Dry_run.log "would write %s" reqs_file
  else (
    let json = Requirements.to_json req in
    config.system#atomic_write [Open_wronly;Open_text] reqs_file ~mode:0o644 (fun ch ->
      Yojson.Basic.to_channel ch json
    );
  )

let create_app config name requirements =
  validate_name "application" name;

  let apps_dir = Basedir.save_path config.system (config_site +/ "apps") config.basedirs.Basedir.config in
  let app_dir = apps_dir +/ name in
  if U.is_dir config.system app_dir then
    raise_safe "Application '%s' already exists: %s" name app_dir;

  config.system#mkdir app_dir 0o755;

  set_requirements config app_dir requirements;
  if not config.dry_run then
    set_last_checked config.system app_dir;

  app_dir

(* Try to guess the command to set an environment variable. *)
let export (system:system) name value =
  let shell = default "/bin/sh" @@ system#getenv "SHELL" in
  try ignore @@ Str.search_forward (Str.regexp_string "csh") shell 0; Printf.sprintf "setenv %s %s" name value
  with Not_found -> Printf.sprintf "export %s=%s" name value

let find_bin_dir_in ~warn_about_path config paths =
  let system = config.system in
  let cache_home = List.hd config.basedirs.Support.Basedir.cache in
  let best =
    paths |> U.first_match (fun path ->
      let path = U.realpath system path in
      let starts x = U.starts_with path x in
      if starts "/bin" || starts "/sbin" then None
      else if starts cache_home then None (* print "Skipping cache: %s" path *)
      else (
        try
          Unix.(access path [W_OK]);
          (* /usr/local/bin is OK if we're running as root *)
          if starts "/usr/" && not (starts "/usr/local/bin") then None
          else Some path
        with Unix.Unix_error _ -> None
      )
    ) in

    match best with
    | Some path -> path
    | None ->
        let path = U.getenv_ex system "HOME" +/ "bin" in
        if warn_about_path then
          log_warning "%s is not in $PATH. Add it with:\n%s" path (export system "PATH" @@ path ^ ":$PATH");
        U.makedirs system path 0o755;
	path

(** Find the first writable path in the list (default $PATH),
    skipping /bin, /sbin and everything under /usr except /usr/local/bin *)
let find_bin_dir ?(warn_about_path=true) config =
  let path = default "/bin:/usr/bin" @@ config.system#getenv "PATH" in
  find_bin_dir_in ~warn_about_path config @@ Str.split_delim U.re_path_sep path

let command_template : (_,_,_) format = "#!/bin/sh\n\
exec 0install run %s \"$@\"\n"

(** Place an executable in $PATH that will launch this app. *)
let integrate_shell config app executable_name =
  (* todo: remember which commands we create *)
  validate_name "executable" executable_name;

  let bin_dir = find_bin_dir config in
  let launcher = bin_dir +/ executable_name in
  if config.system#file_exists launcher then
    raise_safe "Command already exists: %s" launcher;

  if config.dry_run then
    Dry_run.log "would write launcher script %s" launcher
  else (
    config.system#atomic_write [Open_wronly;Open_text] launcher ~mode:0o755 (fun ch ->
      Printf.fprintf ch command_template (Filename.basename app)
    )
  )

let destroy config app =
  let system = config.system in
  assert (system#file_exists @@ app +/ "requirements.json");  (* Safety check that this really is an app *)

  let () = (* delete launcher script, if any *)
    (* todo: remember which commands we own instead of guessing *)
    let name = Filename.basename app in
    let bin_dir = find_bin_dir ~warn_about_path:false config in
    let launcher = bin_dir +/ name in
    let expanded_template = Printf.sprintf command_template name in
    match config.system#stat launcher with
    | None -> ()
    | Some info when info.Unix.st_size = String.length expanded_template ->
        if U.read_file system launcher = expanded_template then (
          if config.dry_run then
            Dry_run.log "would delete launcher script %s" launcher
          else
            system#unlink launcher
        )
    | Some _ -> log_warning "'%s' exists, but doesn't look like our launcher, so not deleting it" launcher in

    if config.dry_run then
      Dry_run.log "would delete directory %s" app
    else
      U.rmtree ~even_if_locked:false system app

(** Get the dates of the available snapshots, starting with the most recent. *)
let get_history config app =
  let re_date = Str.regexp "selections-\\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\\).xml" in
  match config.system#readdir app with
  | Problem ex -> raise ex
  | Success items ->
      let snapshots = ref [] in
      for i = Array.length items - 1 downto 0 do
        let item = items.(i) in
        if Str.string_match re_date item 0 then (
          snapshots := Str.matched_group 1 item :: !snapshots
        )
      done;
      List.sort (fun a b -> compare b a) !snapshots
