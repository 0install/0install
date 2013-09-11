(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interacting with distribution package managers. *)

open General
open Support
open Support.Common
module U = Support.Utils
module Q = Support.Qdom

exception Fallback_to_Python

class virtual distribution (system:system) =
  object (self)
    val virtual distro_name : string
    val system_paths = ["/usr/bin"; "/bin"; "/usr/sbin"; "/sbin"]

    (** Can we use packages for this distribution? For example, MacPortsDistribution can use "MacPorts" and "Darwin" packages. *)
    method match_name name = (name = distro_name)

    (** Test whether this <selection> element is still valid *)
    method virtual is_installed : Support.Qdom.element -> bool

    method virtual get_package_impls : (Support.Qdom.element * Feed.properties) -> Feed.implementation list

    method virtual get_all_package_impls : Feed.feed -> Feed.implementation list option

    (** Called when an installed package is added, or when installation completes. This is useful to fix up the main value.
        The default implementation checks that main exists, and searches [system_paths] for
        it if not. *)
    method private fixup_main props =
      let open Feed in
      match get_command_opt "run" props.commands with
      | None -> ()
      | Some run ->
          match ZI.get_attribute_opt "path" run.command_qdom with
          | None -> ()
          | Some path ->
              if Filename.is_relative path || not (system#file_exists path) then (
                (* Need to search for the binary *)
                let basename = Filename.basename path in
                let basename = if on_windows && not (Filename.check_suffix path ".exe") then basename ^ ".exe" else basename in
                let check_path d =
                  let path = d +/ basename in
                  if system#file_exists path then (
                    log_info "Found %s by searching system paths" path;
                    Qdom.set_attribute "path" path run.command_qdom;
                    true
                  ) else false in
                if not @@ List.exists check_path system_paths then
                  log_info "Binary '%s' not found in any system path (checked %s)" basename (String.concat ", " system_paths)
              )

    (** Helper for [get_package_impls]. *)
    method private make_package_implementation elem props ~id ~version ~machine ~extra_attrs ~is_installed =
      self#fixup_main props;
      let new_attrs = ref props.Feed.attrs in
      let set name value =
        new_attrs := Feed.AttrMap.add ("", name) value !new_attrs in
      set "id" id;
      set "version" version;
      set "from-feed" @@ "distribution:" ^ (Feed.AttrMap.find ("", "from-feed") !new_attrs);
      List.iter (fun (n, v) -> set n v) extra_attrs;
      let open Feed in {
        qdom = elem;
        os = None;
        machine = Arch.none_if_star machine;
        stability = Packaged;
        props = {props with attrs = !new_attrs};
        parsed_version = Versions.parse_version version;
        impl_type = PackageImpl { package_installed = is_installed; package_distro = distro_name; retrieval_method = None };
      }

    (** Check (asynchronously) for available but currently uninstalled candidates. Once the returned
        promise resolves, the candidates should be included in the response from get_package_impls. *)
    method virtual check_for_candidates : Feed.feed -> unit Lwt.t
  end

let package_impl_from_json elem props json =
  let open Feed in
  let pkg_type = ref @@ { package_installed = false; package_distro = "unknown"; retrieval_method = None } in
  let new_props = ref props in
  let pkg = ref {
    qdom = elem;
    os = None;
    machine = None;
    stability = Packaged;
    props;                                (* (gets overwritten later) *)
    parsed_version = Versions.dummy;
    impl_type = PackageImpl !pkg_type;    (* (gets overwritten later) *)
  } in
  let new_attrs = ref props.Feed.attrs in

  let set name value =
    new_attrs := Feed.AttrMap.add ("", name) value !new_attrs in

  set "from-feed" @@ "distribution:" ^ (Feed.AttrMap.find ("", "from-feed") !new_attrs);
  set "stability" "packaged";   (* The GUI likes to know the upstream stability too *)

  let fixup_main path =
    (* The Python code might add or modify the main executable path. *)
    let run_command =
      try
        let command = StringMap.find "run" !new_props.commands in
        let new_elem = {command.command_qdom with Qdom.attrs = command.command_qdom.Qdom.attrs} in  (* Silly syntax for making a copy *)
        Qdom.set_attribute "path" path new_elem;
        {command with command_qdom = new_elem}
      with Not_found ->
        make_command elem.Qdom.doc "run" path in
    new_props := {!new_props with commands = StringMap.add "run" run_command !new_props.commands} in

  match json with
  | `Assoc lst ->
      ListLabels.iter lst ~f:(function
        | ("id", `String v) -> set "id" v
        | ("version", `String v) -> set "version" v; pkg := {!pkg with parsed_version = Versions.parse_version v}
        | ("machine", `String v) -> pkg := {!pkg with machine = Arch.none_if_star v}
        | ("machine", `Null) -> ()
        | ("is_installed", `Bool v) -> pkg_type := {!pkg_type with package_installed = v}
        | ("distro", `String v) -> pkg_type := {!pkg_type with package_distro = v}
        | ("retrieval_method", json) -> pkg_type := {!pkg_type with retrieval_method = Some (Yojson.Basic.Util.to_assoc json)}
        | ("quick-test-file", `String v) -> set "quick-test-file" v
        | ("quick-test-mtime", `String v) -> set "quick-test-mtime" v
        | ("main", `String v) -> fixup_main v
        | (k, v) -> raise_safe "Bad JSON response '%s=%s'" k (Yojson.Basic.to_string v)
      );
      {!pkg with impl_type = PackageImpl !pkg_type; props = {!new_props with attrs = !new_attrs}}
  | _ -> raise_safe "Bad JSON: %s" (Yojson.Basic.to_string json)

(** Return the <package-implementation> elements that best match this distribution. *)
let get_matching_package_impls (distro : #distribution) feed =
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

let make_restricts_distro doc iface_uri distros =
  let elem = ZI.make doc "restricts" in
  let open Feed in {
    dep_qdom = elem;
    dep_importance = Dep_restricts;
    dep_iface = iface_uri;
    dep_restrictions = [make_distribtion_restriction distros];
    dep_required_commands = [];
    dep_if_os = None;
    dep_use = None;
  }

class virtual python_fallback_distribution (slave:Python.slave) =
  object (self)
    inherit distribution slave#system

    val mutable did_packagekit_query = false

    method is_installed elem =
      log_info "No is_installed implementation for '%s'; using slow Python fallback instead!" distro_name;
      slave#invoke ~xml:elem (`List [`String "is-distro-package-installed"]) Yojson.Basic.Util.to_bool

    method get_all_package_impls feed =
      match get_matching_package_impls self feed with
      | [] -> None
      | matches ->
          try
            if did_packagekit_query then raise Fallback_to_Python;
            Some (List.concat (List.map self#get_package_impls matches))
          with Fallback_to_Python ->
            let fake_feed = ZI.make feed.Feed.root.Q.doc "interface" in
            fake_feed.Q.child_nodes <- List.map fst matches;
            let request = `List [`String "get-package-impls"; `String feed.Feed.url] in

            let to_impls (elem, props) = function
              | `List pkgs -> List.map (package_impl_from_json elem props) pkgs
              | _ -> raise_safe "Not a group list" in

            (* Process "host" package implementations. These weren't added by any particular
               <package-implementation>, so we'll have to fake up a source element. *)
            let to_host_impl lst =
              let elem = ZI.make fake_feed.Qdom.doc "host-package-implementation" in
              let restrictions =
                if feed.Feed.url = "http://repo.roscidus.com/python/python-gobject" then (
                  [make_restricts_distro elem.Qdom.doc "http://repo.roscidus.com/python/python" "host"]
                ) else [] in
              let props = Feed.({
                attrs = Feed.AttrMap.singleton ("", "from-feed") feed.Feed.url;
                requires = restrictions;
                bindings = [];
                commands = StringMap.empty;
              }) in
              to_impls (elem, props) lst in

            slave#invoke ~xml:fake_feed request (function
              | `List (host::pkg_groups) ->
                  let host_impls = to_host_impl host in
                  Some (List.concat (host_impls :: List.map2 to_impls matches pkg_groups))
              | _ -> raise_safe "Invalid response"
            )

    method get_package_impls _ = raise Fallback_to_Python

    method check_for_candidates feed =
      match get_matching_package_impls self feed with
      | [] -> Lwt.return ()
      | matches ->
          did_packagekit_query <- true;
          let fake_feed = ZI.make feed.Feed.root.Q.doc "interface" in
          fake_feed.Q.child_nodes <- List.map fst matches;
          let request = `List [`String "get-distro-candidates"; `String feed.Feed.url] in
          slave#invoke_async ~xml:fake_feed request ignore
  end

class generic_distribution slave =
  object
    inherit python_fallback_distribution slave
    val distro_name = "fallback"
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
      let re_metadata_sep = if old_format then re_colon_space else U.re_equals
      and re_key_value_sep = if old_format then U.re_tab else U.re_equals
      in
      object (self)
        (* The status of the cache when we loaded it. *)
        val data = { mtime = 0L; size = -1; rev = -1; contents = Hashtbl.create 10 }

        val cache_path = (Basedir.save_path config.system (config_site +/ config_prog) config.basedirs.Basedir.cache) +/ cache_leaf

        (** Reload the values from disk (even if they're out-of-date). *)
        method load_cache () =
          data.mtime <- -1L;
          data.size <- -1;
          data.rev <- -1;
          Hashtbl.clear data.contents;

          if Sys.file_exists cache_path then (
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
      Qdom.log_elem Support.Logging.Warning "Missing 'package' attribute" elem;
      false
  | Some package ->
      let sel_id = ZI.get_attribute "id" elem in
      let matches data =
          let installed_version, machine = Utils.split_pair U.re_tab data in
          let installed_id = Printf.sprintf "package:%s:%s:%s:%s" distro_name package installed_version machine in
          (* log_warning "Want %s %s, have %s" package sel_id installed_id; *)
          sel_id = installed_id in
      List.exists matches (cache#get package)

module Debian = struct
  let dpkg_db_status = "/var/lib/dpkg/status"

  class debian_distribution config slave =
    object (self)
      inherit python_fallback_distribution slave as super

      val distro_name = "Debian"
      val cache = new Cache.cache config "dpkg-status.cache" dpkg_db_status 2 ~old_format:false

      method! is_installed elem =
        try check_cache "deb" elem cache
        with Fallback_to_Python -> super#is_installed elem

      method! get_package_impls (elem, props) =
        let package_name = ZI.get_attribute "package" elem in
        let process cached_info =
          match Str.split_delim U.re_tab cached_info with
          | [version; machine] ->
              let id = Printf.sprintf "package:deb:%s:%s:%s" package_name version machine in
              self#make_package_implementation elem props ~is_installed:true
                ~id ~version ~machine ~extra_attrs:[]
          | _ ->
              log_warning "Unknown cache line format for '%s': %s" package_name cached_info;
              raise Fallback_to_Python
        in

        match cache#get package_name with
        | [] -> raise Fallback_to_Python      (* We don't know anything about this package *)
        | ["-"] -> []                         (* We know the package isn't installed *)
        | infos -> List.map process infos
    end
end

module RPM = struct
  let rpm_db_packages = "/var/lib/rpm/Packages"

  class rpm_distribution config slave =
    object
      inherit python_fallback_distribution slave as super

      val distro_name = "RPM"
      val cache = new Cache.cache config "rpm-status.cache" rpm_db_packages 2 ~old_format:true

      method! is_installed elem =
        try check_cache "rpm" elem cache
        with Fallback_to_Python -> super#is_installed elem
    end
end

module ArchLinux = struct
  let arch_db = "/var/lib/pacman"
  let packages_dir = "/var/lib/pacman/local"

  class arch_distribution config slave =
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

    object (self : #distribution)
      inherit python_fallback_distribution slave

      val distro_name = "Arch"

      method! is_installed elem =
        (* We should never get here, because we always set quick-test-* *)
        Qdom.log_elem Logging.Info "Old selections file; forcing an update of" elem;
        false

(* Still need to fall back in the case where we queried for package-kit candidates, so
 * use base-class.
      method get_all_package_impls feed =
        match get_matching_package_impls self feed with
        | [] -> None
        | matches -> Some (List.concat (List.map self#get_package_impls matches))
*)

      method! get_package_impls (elem, props) =
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
                    self#make_package_implementation elem props ~is_installed:true ~id ~version ~machine ~extra_attrs:[("quick-test-file", desc_path)];
                  ]
        with Not_found -> []
    end
end

module Mac = struct
  let macports_db = "/opt/local/var/macports/registry/registry.db"

  (* Note: we currently don't have or need DarwinDistribution, because that uses quick-test-* attributes *)

  class macports_distribution config slave =
    object
      inherit python_fallback_distribution slave as super

      val! system_paths = ["/opt/local/bin"]

      val distro_name = "MacPorts"
      val cache = new Cache.cache config "macports-status.cache" macports_db 2 ~old_format:true

      method! is_installed elem =
        try check_cache "macports" elem cache
        with Fallback_to_Python -> super#is_installed elem

      method! match_name name = (name = distro_name || name = "Darwin")
    end
end

module Win = struct
  class windows_distribution _config slave =
    object
      inherit python_fallback_distribution slave

      val! system_paths = []

      val distro_name = "Windows"
      method! get_package_impls (elem, _props) =
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

  class cygwin_distribution config slave =
    object
      inherit python_fallback_distribution slave as super

      val distro_name = "Cygwin"
      val cache = new Cache.cache config "cygcheck-status.cache" cygwin_log 2 ~old_format:true

      method! is_installed elem =
        try check_cache "cygwin" elem cache
        with Fallback_to_Python -> super#is_installed elem
    end
end

let get_host_distribution config (slave:Python.slave) : distribution =
  let x = Sys.file_exists in

  match Sys.os_type with
  | "Unix" ->
      let is_debian =
        match config.system#stat Debian.dpkg_db_status with
        | Some info when info.Unix.st_size > 0 -> true
        | _ -> false in

      if is_debian then
        new Debian.debian_distribution config slave
      else if x ArchLinux.arch_db then
        new ArchLinux.arch_distribution config slave
      else if x RPM.rpm_db_packages then
        new RPM.rpm_distribution config slave
      else if x Mac.macports_db then
        new Mac.macports_distribution config slave
      else
        new generic_distribution slave
  | "Win32" -> new Win.windows_distribution config slave
  | "Cygwin" -> new Win.cygwin_distribution config slave
  | _ ->
      new generic_distribution slave
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

(** Get the native implementations (installed or candidates for installation), based on the <package-implementation> elements
    in [feed]. Returns [None] if there were no matching elements (which means that we didn't even check the distribution). *)
let get_package_impls (distro : distribution) feed =
  distro#get_all_package_impls feed
