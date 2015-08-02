(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A simple cache for storing key-value pairs on disk. Distributions may wish to use this to record the
    version(s) of each distribution package currently installed. *)

open Support.Common
open General

module U = Support.Utils
module Basedir = Support.Basedir

type package_name = string
type entry = Version.t * Arch.machine option

type cache_data = {
  mutable mtime : Int64.t;
  mutable size : int;
  contents : (package_name, entry list) Hashtbl.t;
}

let re_invalid = Str.regexp ".*[\t\n]"

let validate_key k =
  assert (not (Str.string_match re_invalid k 0))

class cache (config:General.config) ~(cache_leaf:string) (source:filepath) =
  let warned_missing = ref false in
  let re_metadata_sep = U.re_equals
  and re_key_value_sep = U.re_tab in

  let add_entry ch package_name (version, machine) =
    validate_key package_name;
    Printf.fprintf ch "%s\t%s\t%s\n" package_name (Version.to_string version) (Arch.format_machine_or_star machine) in

  object (self)
    (* The status of the cache when we loaded it. *)
    val data = { mtime = 0L; size = -1; contents = Hashtbl.create 10 }

    val cache_path = Basedir.save_path config.system (config_site +/ config_prog) config.basedirs.Basedir.cache +/ cache_leaf

    (** Reload the values from disk (even if they're out-of-date). *)
    method private load_cache =
      data.mtime <- -1L;
      data.size <- -1;
      Hashtbl.clear data.contents;

      if Sys.file_exists cache_path then (
        try
          cache_path |> config.system#with_open_in [Open_rdonly; Open_text] (fun ch ->
            let headers = ref true in
            while !headers do
              match input_line ch with
              | "" -> headers := false
              | line ->
                  (* log_info "Cache header: %s" line; *)
                  match U.split_pair re_metadata_sep line with
                  | ("mtime", mtime) -> data.mtime <- Int64.of_string mtime
                  | ("size", size) -> data.size <- U.safe_int_of_string size
                  | _ -> ()
            done;

            try
              while true do
                let line = input_line ch in
                let key, value = U.split_pair re_key_value_sep line in
                let prev = try Hashtbl.find data.contents key with Not_found -> [] in
                if value = "-" then (
                  Hashtbl.replace data.contents key prev    (* Ensure empty list is in the table *)
                ) else (
                  let version, machine = U.split_pair U.re_tab value in
                  Hashtbl.replace data.contents key @@ (Version.parse version, Arch.parse_machine machine) :: prev
                )
              done
            with End_of_file -> ()
          )
        with ex ->
          log_warning ~ex "Failed to load cache file '%s' (maybe corrupted; try deleting it)" cache_path
      )

    (** Add some entries to the cache. *)
    method private put key values =
      try
        Hashtbl.replace data.contents key values;
        cache_path |> config.system#with_open_out [Open_append; Open_creat] ~mode:0o644 (fun ch ->
          if values = [] then (
            validate_key key;
            Printf.fprintf ch "%s\t-\n" key (* Cache negative results too *)
          ) else (
            values |> List.iter (add_entry ch key)
          )
        )
      with Safe_exception _ as ex -> reraise_with_context ex "... writing cache %s" cache_path

    (** Check cache is still up-to-date (i.e. that [source] hasn't changed). Clear it if not. *)
    method private ensure_valid =
      match config.system#stat source with
      | None ->
          if not !warned_missing then (
            log_warning "Package database '%s' missing!" source;
            warned_missing := true
          )
      | Some info ->
          let flush () =
            cache_path |> config.system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
              let mtime = Int64.of_float info.Unix.st_mtime |> Int64.to_string in
              Printf.fprintf ch "mtime=%s\nsize=%d\n\n" mtime info.Unix.st_size;
              self#regenerate_cache (add_entry ch)
            );
            self#load_cache in
          let actual_mtime = Int64.of_float info.Unix.st_mtime in
          if data.mtime <> actual_mtime then (
            if data.mtime <> -1L then
              log_info "Modification time of %s has changed; invalidating cache" source;
            flush ()
          ) else if data.size <> info.Unix.st_size then (
            log_info "Size of %s has changed; invalidating cache" source;
            flush ()
          )

    method private regenerate_cache _add = ()

    method get ?if_missing (key:package_name) : (entry list * Distro.quick_test option) =
      self#ensure_valid;
      let entries =
        try Hashtbl.find data.contents key
        with Not_found ->
          match if_missing with
          | None -> []
          | Some if_missing ->
              let result = if_missing key in
              self#put key result;
              result in
      let quick_test_file = Some (source, Distro.UnchangedSince (Int64.to_float data.mtime)) in
      (entries, quick_test_file)

    initializer self#load_cache
  end
