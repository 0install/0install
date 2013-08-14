(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interacting with distribution package managers. *)

open General
open Support
open Support.Common
module U = Support.Utils

class type distribution =
  object
    (** The distribution name, as seen in <package-implementation>'s distribution attribute. *)
    val distro_name : string

    (** Test whether this <selection> element is still valid *)
    method is_installed : Support.Qdom.element -> bool

    (** Can we use packages for this distribution? For example, MacPortsDistribution can use "MacPorts" and "Darwin" packages. *)
    method match_name : string -> bool

    method get_package_impls : (Support.Qdom.element * Feed.properties) -> Feed.implementation list
  end

class base_distribution : distribution =
  object
    val distro_name = "fallback"

    method is_installed elem =
      log_warning "FIXME: Assuming distribution package %s version %s is still installed"
                  (ZI.get_attribute "id" elem) (ZI.get_attribute "version" elem);
      true

    method match_name name = (name = distro_name)

    method get_package_impls _elem = raise Fallback_to_Python
  end

let try_cleanup_distro_version_ex version package_name =
  match Versions.try_cleanup_distro_version version with
  | None -> log_warning "Can't parse distribution version '%s' for package '%s'" version package_name; None
  | version -> version

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

(** Helper for [get_package_impls]. *)
let make_package_implementation elem props ~id ~version ~machine ~extra_attrs ~is_installed ~distro_name =
  let new_attrs = ref props.Feed.attrs in
  let set name value =
    new_attrs := Feed.AttrMap.add ("", name) value !new_attrs in
  set "id" id;
  set "version" version;
  List.iter (fun (n, v) -> set n v) extra_attrs;
  let open Feed in {
    qdom = elem;
    os = None;
    machine = Arch.none_if_star machine;
    stability = Packaged;
    props = {props with attrs = !new_attrs};
    parsed_version = Versions.parse_version version;
    impl_type = PackageImpl { package_installed = is_installed; package_distro = distro_name };
  }

module Debian = struct
  let dpkg_db_status = "/var/lib/dpkg/status"

  class debian_distribution config : distribution =
    object
      val distro_name = "Debian"
      val cache = new Cache.cache config "dpkg-status.cache" dpkg_db_status 2 ~old_format:false
      method is_installed elem = check_cache "deb" elem cache
      method match_name name = (name = distro_name)
      method get_package_impls _elem = raise Fallback_to_Python
    end
end

module RPM = struct
  let rpm_db_packages = "/var/lib/rpm/Packages"

  class rpm_distribution config : distribution =
    object
      val distro_name = "RPM"
      val cache = new Cache.cache config "rpm-status.cache" rpm_db_packages 2 ~old_format:true
      method is_installed elem = check_cache "rpm" elem cache
      method match_name name = (name = distro_name)
      method get_package_impls _elem = raise Fallback_to_Python
    end
end

module ArchLinux = struct
  let arch_db = "/var/lib/pacman"
  let packages_dir = "/var/lib/pacman/local"

  class arch_distribution config : distribution =
    let parse_dirname entry =
      try
        let build_dash = String.rindex entry '-' in
        let version_dash = String.rindex_from entry (build_dash - 1) '-' in
        Some (String.sub entry 0 version_dash,
              U.string_tail entry (version_dash + 1))
      with Not_found -> None in

    let get_arch desc_path =
      let arch = ref None in
      let read ch =
        try
          while !arch = None do
            let line = input_line ch in
            if line = "%ARCH%" then
              arch := Some (trim (input_line ch))
          done
        with End_of_file -> () in
      config.system#with_open_in [Open_rdonly; Open_text] 0 desc_path read;
      !arch in

    let entries = ref (-1.0, StringMap.empty) in
    let get_entries () =
      let (last_read, items) = !entries in
      match config.system#stat packages_dir with
      | Some info when info.Unix.st_mtime > last_read -> (
          match config.system#readdir packages_dir with
          | Success items ->
              let add map entry =
                match parse_dirname entry with
                | Some (name, version) -> StringMap.add name version map
                | None -> map in
              let new_items = Array.fold_left add StringMap.empty items in
              entries := (info.Unix.st_mtime, new_items);
              new_items
          | Problem ex ->
              log_warning ~ex "Can't read packages dir '%s'!" packages_dir;
              items
      )
      | _ -> items in

    object (_ : #distribution)
      val distro_name = "Arch"
      method is_installed elem =
        (* We should never get here, because we always set quick-test-* *)
        Qdom.log_elem Logging.Info "Old selections file; forcing an update of" elem;
        false
      method match_name name = (name = distro_name)

      method get_package_impls (elem, props) =
        let package_name = ZI.get_attribute "package" elem in
        log_debug "Looking up distribution packages for %s" package_name;
        let items = get_entries () in
        try
          let version = StringMap.find package_name items in
          let entry = package_name ^ "-" ^ version in
          let desc_path = packages_dir +/ entry +/ "desc" in
          match get_arch desc_path with
          | None ->
              log_warning "No ARCH in %s" desc_path; []
          | Some arch ->
              let machine = Support.System.canonical_machine arch in
              match try_cleanup_distro_version_ex version package_name with
              | None -> []
              | Some version ->
                  let id = Printf.sprintf "package:arch:%s:%s:%s" package_name version machine in [
                    make_package_implementation elem props ~distro_name ~is_installed:true ~id ~version ~machine ~extra_attrs:[("quick-test-file", desc_path)];
                  ]
        with Not_found -> []
    end
end

module Mac = struct
  let macports_db = "/opt/local/var/macports/registry/registry.db"

  (* Note: we currently don't have or need DarwinDistribution, because that uses quick-test-* attributes *)

  class macports_distribution config : distribution =
    object
      val distro_name = "MacPorts"
      val cache = new Cache.cache config "macports-status.cache" macports_db 2 ~old_format:true
      method is_installed elem = check_cache "macports" elem cache
      method match_name name = (name = distro_name || name = "Darwin")
      method get_package_impls _elem = raise Fallback_to_Python
    end
end

module Win = struct
  class windows_distribution _config : distribution =
    object
      val distro_name = "Windows"
      method is_installed _elem = raise Fallback_to_Python
      method match_name name = (name = distro_name)
      method get_package_impls (elem, _props) =
        let package_name = ZI.get_attribute "package" elem in
        match package_name with
        | "openjdk-6-jre" | "openjdk-6-jdk"
        | "openjdk-7-jre" | "openjdk-7-jdk"
        | "netfx" | "netfx-client" ->
            Qdom.log_elem Support.Logging.Info "FIXME: Windows: can't check for package '%s':" package_name elem;
            raise Fallback_to_Python
        | _ -> []
    end

  let cygwin_log = "/var/log/setup.log"

  class cygwin_distribution config : distribution =
    object
      val distro_name = "Cygwin"
      val cache = new Cache.cache config "cygcheck-status.cache" cygwin_log 2 ~old_format:true
      method is_installed elem = check_cache "cygwin" elem cache
      method match_name name = (name = distro_name)
      method get_package_impls _elem = raise Fallback_to_Python
    end
end

let get_host_distribution config : distribution =
  let x = Sys.file_exists in

  match Sys.os_type with
  | "Unix" ->
      if x Debian.dpkg_db_status && (Unix.stat Debian.dpkg_db_status).Unix.st_size > 0 then
        new Debian.debian_distribution config
      else if x ArchLinux.arch_db then
        new ArchLinux.arch_distribution config
      else if x RPM.rpm_db_packages then
        new RPM.rpm_distribution config
      else if x Mac.macports_db then
        new Mac.macports_distribution config
      else
        new base_distribution
  | "Win32" -> new Win.windows_distribution config
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

(** Return the <package-implementation> elements that best match this distribution. *)
let get_matching_package_impls (distro : distribution) feed =
  let best_score = ref 0 in
  let best_impls = ref [] in
  ListLabels.iter feed.Feed.package_implementations ~f:(function (elem, _) as package_impl ->
    let distributions = default "" @@ ZI.get_attribute_opt "distributions" elem in
    let distro_names = Str.split_delim U.re_space distributions in
    let score_this_item =
      if distro_names = [] then 1                                 (* Generic <package-implementation>; no distribution specified *)
      else if List.exists distro#match_name distro_names then 2   (* Element specifies it matches this distribution *)
      else 0 in                                                   (* Element's distributions do not match *)
    if score_this_item > !best_score then (
      best_score := score_this_item;
      best_impls := []
    );
    if score_this_item = !best_score then (
      best_impls := package_impl :: !best_impls
    )
  );
  !best_impls

(** Get the native implementations (installed or candidates for installation), based on the <package-implementation> elements
    in [feed]. Returns [None] if there were no matching elements (which means that we didn't even check the distribution). *)
let get_package_impls (distro : distribution) feed =
  match get_matching_package_impls distro feed with
  | [] -> None
  | matches -> Some (List.concat (List.map distro#get_package_impls matches))
