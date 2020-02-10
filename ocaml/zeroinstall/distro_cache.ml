(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A simple cache for storing key-value pairs on disk. Distributions may wish to use this to record the
    version(s) of each distribution package currently installed. *)

open Support
open Support.Common
open General

type package_name = string
type entry = Version.t * Arch.machine option

type cache_data = {
  source : filepath;      (* The distribution's cache file *)
  cache_path : filepath;  (* Our cache of [source]. *)
  mutable warned_missing : bool;  (* True if we've already logged that source is missing *)
  (* The status of the cache when we loaded it. *)
  mutable mtime : Int64.t;
  mutable size : int;
  content : (package_name, entry list) Hashtbl.t;
}

let re_invalid = Str.regexp ".*[\t\n]"
let re_metadata_sep = XString.re_equals
let re_key_value_sep = XString.re_tab

let validate_key k =
  assert (not (Str.string_match re_invalid k 0))

let add_entry ch package_name (version, machine) =
  validate_key package_name;
  Printf.fprintf ch "%s\t%s\t%s\n" package_name (Version.to_string version) (Arch.format_machine_or_star machine)

(* Reload the values from disk (even if they're out-of-date). *)
let load_cache config data =
  data.mtime <- -1L;
  data.size <- -1;
  Hashtbl.clear data.content;
  if Sys.file_exists data.cache_path then (
    try
      data.cache_path |> config.system#with_open_in [Open_rdonly; Open_text] (fun ch ->
        let rec read_headers () =
          match input_line ch with
          | "" -> `End_of_headers
          | line ->
              (* log_info "Cache header: %s" line; *)
              begin match XString.split_pair_safe re_metadata_sep line with
              | ("mtime", mtime) -> data.mtime <- Int64.of_string mtime
              | ("size", size) -> data.size <- XString.to_int_safe size
              | _ -> () end;
              read_headers () in
        let `End_of_headers = read_headers () in
        try
          while true do
            let line = input_line ch in
            let key, value = XString.split_pair_safe re_key_value_sep line in
            let prev = try Hashtbl.find data.content key with Not_found -> [] in
            if value = "-" then (
              Hashtbl.replace data.content key prev    (* Ensure empty list is in the table *)
            ) else (
              let version, machine = XString.(split_pair_safe re_tab) value in
              Hashtbl.replace data.content key @@ (Version.parse version, Arch.parse_machine machine) :: prev
            )
          done
        with End_of_file -> ()
      )
    with ex ->
      log_warning ~ex "Failed to load cache file '%s' (maybe corrupted; try deleting it)" data.cache_path
  )

(* Check cache is still up-to-date (i.e. that [source] hasn't changed). Clear/regenerate it if not. *)
let ensure_valid ?regenerate config data =
  match config.system#stat data.source with
  | None when data.warned_missing -> ()
  | None ->
      log_warning "Package database '%s' missing!" data.source;
      data.warned_missing <- true
  | Some info ->
      let flush () =
        if config.dry_run then Dry_run.log "would regenerate %s" data.cache_path
        else (
          data.cache_path |> config.system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
              let mtime = Int64.of_float info.Unix.st_mtime in
              Printf.fprintf ch "mtime=%Ld\nsize=%d\n\n" mtime info.Unix.st_size;
              regenerate |> if_some (fun f -> f (add_entry ch))
            );
          load_cache config data
        ) in
      let actual_mtime = Int64.of_float info.Unix.st_mtime in
      if data.mtime <> actual_mtime then (
        if data.mtime <> -1L then
          log_info "Modification time of %s has changed; invalidating cache" data.source;
        flush ()
      ) else if data.size <> info.Unix.st_size then (
        log_info "Size of %s has changed; invalidating cache" data.source;
        flush ()
      )

let create ~config ~cache_leaf ~source =
  let cache_path = Paths.Cache.(save_path (distro_cache cache_leaf)) config.paths in
  let data = { source; cache_path; mtime = 0L; size = -1; content = Hashtbl.create 10; warned_missing = false } in
  load_cache config data;
  data

type t = package_name -> entry list * Distro.quick_test option

let quick_test_file data = Some (data.source, Distro.UnchangedSince (Int64.to_float data.mtime))

let create_eager config ~cache_leaf ~source ~regenerate =
  let data = create ~config ~cache_leaf ~source in
  fun key ->
    ensure_valid config data ~regenerate;
    let entries = try Hashtbl.find data.content key with Not_found -> [] in
    (entries, quick_test_file data)

let create_lazy config ~cache_leaf ~source ~if_missing =
  let data = create ~config ~cache_leaf ~source in
  (* Add some entries to the cache. *)
  let put key values =
    try
      Hashtbl.replace data.content key values;
      if config.dry_run then
        Dry_run.log "would update %s (%s)" data.cache_path key
      else (
        data.cache_path |> config.system#with_open_out [Open_append; Open_creat] ~mode:0o644 (fun ch ->
            if values = [] then (
              validate_key key;
              Printf.fprintf ch "%s\t-\n" key (* Cache negative results too *)
            ) else (
              values |> List.iter (add_entry ch key)
            )
          )
      )
    with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... writing cache %s" data.cache_path in
  fun key ->
    ensure_valid config data;
    let entries =
      try Hashtbl.find data.content key
      with Not_found ->
        let result = if_missing key in
        put key result;
        result in
    (entries, quick_test_file data)

let get t key = t key
