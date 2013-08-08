(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interacting with distribution package managers. *)

open General
open Support
open Support.Common

class type distribution =
  object
    (** The distribution name, as seen in <package-implementation>'s distribution attribute. *)
    (** Test whether this <selection> element is still valid *)
    method is_installed : Support.Qdom.element -> bool
  end

class base_distribution : distribution =
  object
    method is_installed elem =
      log_warning "FIXME: Assuming distribution package %s version %s is still installed"
                  (ZI.get_attribute "id" elem) (ZI.get_attribute "version" elem);
      true
  end
;;

(** A simple cache for storing key-value pairs on disk. Distributions may wish to use this to record the
    version(s) of each distribution package currently installed. *)
module Cache =
  struct

    type cache_data = {
      mutable mtime : Int64.t;
      mutable size : int;
      mutable rev : int;
      mutable contents : (string, string) Hashtbl.t;
    }

    let re_colon_space = Str.regexp_string ": "

    (* Note: [format_version] doesn't make much sense. If the format changes, just use a different [cache_leaf],
       otherwise you'll be fighting with other versions of 0install.
       The [old_format] used different separator characters.
       *)
    class cache (config:General.config) (cache_leaf:string) (source:filepath) (format_version:int) ~(old_format:bool) =
      let re_metadata_sep = if old_format then re_colon_space else re_equals
      and re_key_value_sep = if old_format then re_tab else re_equals
      in
      object (self)
        (* The status of the cache when we loaded it. *)
        val data = { mtime = 0L; size = -1; rev = -1; contents = Hashtbl.create 10 }

        val cache_path = Basedir.save_path config.system (config_site +/ config_prog +/ cache_leaf) config.basedirs.Basedir.cache

        (** Reload the values from disk (even if they're out-of-date). *)
        method load_cache () =
          data.mtime <- -1L;
          data.size <- -1;
          data.rev <- -1;
          Hashtbl.clear data.contents;

          if Sys.file_exists source then (
            let load_cache ch =
              let headers = ref true in
              while !headers do
                match input_line ch with
                | "" -> headers := false
                | line ->
                    (* log_info "Cache header: %s" line; *)
                    match Utils.split_pair re_metadata_sep line with
                    | ("mtime", mtime) -> data.mtime <- Int64.of_string mtime
                    | ("size", size) -> data.size <- int_of_string size
                    | ("version", rev) when old_format -> data.rev <- int_of_string rev
                    | ("format", rev) when not old_format -> data.rev <- int_of_string rev
                    | _ -> ()
              done;

              try
                while true do
                  let line = input_line ch in
                  let (key, value) = Utils.split_pair re_key_value_sep line in
                  Hashtbl.add data.contents key value   (* note: adds to existing list of packages for this key *)
                done
              with End_of_file -> ()
              
              in
            config.system#with_open_in [Open_rdonly; Open_text] 0 cache_path load_cache
          )

        (** Check cache is still up-to-date. Clear it not. *)
        method ensure_valid () =
          match config.system#stat source with
          | None when data.size = -1 -> ()    (* Still doesn't exist - no problem *)
          | None -> raise Fallback_to_Python  (* Disappeared (shouldn't happen) *)
          | Some info ->
              if data.mtime <> Int64.of_float info.Unix.st_mtime then (
                log_info "Modification time of %s has changed; invalidating cache" source;
                raise Fallback_to_Python
              ) else if data.size <> info.Unix.st_size then (
                log_info "Size of %s has changed; invalidating cache" source;
                raise Fallback_to_Python
              ) else if data.rev <> format_version then (
                log_info "Format of cache %s has changed; invalidating cache" cache_path;
                raise Fallback_to_Python
              )

        method get (key:string) : string list =
          self#ensure_valid ();
          Hashtbl.find_all data.contents key

        initializer self#load_cache ()
      end
  end

(** Lookup [elem]'s package in the cache. Generate the ID(s) for the cached implementations and check that one of them
    matches the [id] attribute on [elem].
    Returns [false] if the cache is out-of-date. *)
let check_cache distro_name elem cache =
  match ZI.get_attribute_opt "package" elem with
  | None ->
      log_warning "Missing 'package' attribute";
      false
  | Some package ->
      let sel_id = ZI.get_attribute "id" elem in
      let matches data =
          let installed_version, machine = Utils.split_pair re_tab data in
          let installed_id = Printf.sprintf "package:%s:%s:%s:%s" distro_name package installed_version machine in
          (* log_warning "Want %s %s, have %s" package sel_id installed_id; *)
          sel_id = installed_id in
      List.exists matches (cache#get package)

module Debian = struct
  let dpkg_db_status = "/var/lib/dpkg/status"

  class debian_distribution config : distribution =
    object
      val cache = new Cache.cache config "dpkg-status.cache" dpkg_db_status 2 ~old_format:false
      method is_installed elem = check_cache "deb" elem cache
    end
end

module RPM = struct
  let rpm_db_packages = "/var/lib/rpm/Packages"

  class rpm_distribution config : distribution =
    object
      val cache = new Cache.cache config "rpm-status.cache" rpm_db_packages 2 ~old_format:true
      method is_installed elem = check_cache "rpm" elem cache
    end
end

module Arch = struct
  let arch_db = "/var/lib/pacman"

  class arch_distribution () : distribution =
    object
      method is_installed elem =
        (* We should never get here, because we always set quick-test-* *)
        Qdom.log_elem Logging.Info "Old selections file; forcing an update of" elem;
        false
    end
end

module Mac = struct
  let macports_db = "/opt/local/var/macports/registry/registry.db"

  (* Note: we currently don't have or need DarwinDistribution, because that uses quick-test-* attributes *)

  class macports_distribution config : distribution =
    object
      val cache = new Cache.cache config "macports-status.cache" macports_db 2 ~old_format:true
      method is_installed elem = check_cache "macports" elem cache
    end
end

module Win = struct
  let cygwin_log = "/var/log/setup.log"

  class cygwin_distribution config : distribution =
    object
      val cache = new Cache.cache config "cygcheck-status.cache" cygwin_log 2 ~old_format:true
      method is_installed elem = check_cache "cygwin" elem cache
    end
end

let get_host_distribution config : distribution =
  (*
  let rpm_db_packages = "/var/lib/rpm/Packages" in
  let slack_db = "/var/log/packages" in
  let pkg_db = "/var/db/pkg" in
  let macports_db = "/opt/local/var/macports/registry/registry.db" in
  let cygwin_log = "/var/log/setup.log" in
  *)

  let x = Sys.file_exists in

  match Sys.os_type with
  | "Unix" ->
      if x Debian.dpkg_db_status && (Unix.stat Debian.dpkg_db_status).Unix.st_size > 0 then
        new Debian.debian_distribution config
      else if x Arch.arch_db then
        new Arch.arch_distribution ()
      else if x RPM.rpm_db_packages then
        new RPM.rpm_distribution config
      else if x Mac.macports_db then
        new Mac.macports_distribution config
      else
        new base_distribution

  | "Win32" -> new base_distribution
  | "Cygwin" -> new Win.cygwin_distribution config

  | _ ->
      new base_distribution
;;

(** Check whether this <selection> is still valid. If the quick-test-* attributes are present, use
    them to check. Otherwise, call the appropriate method on [config.distro]. *)
let is_installed config distro elem =
  match ZI.get_attribute_opt "quick-test-file" elem with
  | None -> distro#is_installed elem
  | Some file ->
      match config.system#stat file with
      | None -> false
      | Some info ->
          match ZI.get_attribute_opt "quick-test-mtime" elem with
          | None -> true      (* quick-test-file exists and we don't care about the time *)
          | Some required_mtime -> (Int64.of_float info.Unix.st_mtime) = Int64.of_string required_mtime
