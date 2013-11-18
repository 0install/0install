(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interacting with distribution package managers. *)

open General
open Support
open Support.Common
module FeedAttr = Constants.FeedAttr
module U = Support.Utils
module Q = Support.Qdom

let generic_distribution slave =
  object
    inherit Distro.python_fallback_distribution slave "Distribution" []
    val check_host_python = true
    val distro_name = "fallback"
    val id_prefix = "package:fallback"
  end

let try_cleanup_distro_version_warn version package_name =
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

    (* Manage the cache named [cache_leaf]. Whenever [source] changes, everything in the cache is assumed to be invalid.
       Note: [format_version] doesn't make much sense. If the format changes, just use a different [cache_leaf],
       otherwise you'll be fighting with other versions of 0install.
       The [old_format] used different separator characters.
       *)
    class cache (config:General.config) (cache_leaf:string) (source:filepath) (format_version:int) ~(old_format:bool) =
      let warned_missing = ref false in
      let re_metadata_sep = if old_format then re_colon_space else U.re_equals
      and re_key_value_sep = if old_format then U.re_tab else U.re_equals
      in
      object (self)
        (* The status of the cache when we loaded it. *)
        val data = { mtime = 0L; size = -1; rev = -1; contents = Hashtbl.create 10 }

        val cache_path = Basedir.save_path config.system (config_site +/ config_prog) config.basedirs.Basedir.cache +/ cache_leaf

        (** Reload the values from disk (even if they're out-of-date). *)
        method private load_cache =
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

        (** Add some entries to the cache.
         * Warning: adding the empty list has no effect. In particular, future calls to [get] will still call [if_missing].
         * So if you want to record the fact that a package is not installed, you see need to add an entry for it (e.g. [["-"]]). *)
        method private put key values =
          try
            config.system#with_open_out [Open_append; Open_creat] 0o644 cache_path (fun ch ->
              values |> List.iter (fun value ->
                output_string ch @@ Printf.sprintf "%s=%s" key value;
                Hashtbl.add data.contents key value
              )
            )
          with Safe_exception _ as ex -> reraise_with_context ex "... writing cache %s: %s=%s" cache_path key (String.concat ";" values)

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
                config.system#atomic_write [Open_wronly; Open_binary] cache_path ~mode:0o644 (fun ch ->
                  let mtime = Int64.of_float info.Unix.st_mtime |> Int64.to_string in
                  Printf.fprintf ch "mtime=%s\nsize=%d\nformat=%d\n\n" mtime info.Unix.st_size format_version
                );
                self#load_cache in
              if data.mtime <> Int64.of_float info.Unix.st_mtime then (
                if data.mtime <> -1L then
                  log_info "Modification time of %s has changed; invalidating cache" source;
                flush ()
              ) else if data.size <> info.Unix.st_size then (
                log_info "Size of %s has changed; invalidating cache" source;
                flush ()
              ) else if data.rev <> format_version then (
                log_info "Format of cache %s has changed; invalidating cache" cache_path;
                flush ()
              )

        (** Look up an item in the cache.
         * @param if_missing called if given and no entries are found
         *)
        method get ?if_missing (key:string) : string list =
          self#ensure_valid;
          match Hashtbl.find_all data.contents key, if_missing with
          | [], Some if_missing ->
              let result = if_missing key in
              self#put key result;
              result
          | result, _ -> result

        initializer self#load_cache
      end
  end

(** Lookup [elem]'s package in the cache. Generate the ID(s) for the cached implementations and check that one of them
    matches the [id] attribute on [elem].
    Returns [false] if the cache is out-of-date. *)
let check_cache id_prefix elem (cache:Cache.cache) =
  match ZI.get_attribute_opt "package" elem with
  | None ->
      Qdom.log_elem Support.Logging.Warning "Missing 'package' attribute" elem;
      false
  | Some package ->
      let sel_id = ZI.get_attribute "id" elem in
      let matches data =
          let installed_version, machine = Utils.split_pair U.re_tab data in
          let installed_id = Printf.sprintf "%s:%s:%s:%s" id_prefix package installed_version machine in
          (* log_warning "Want %s %s, have %s" package sel_id installed_id; *)
          sel_id = installed_id in
      List.exists matches (cache#get package)

module Debian = struct
  let dpkg_db_status = "/var/lib/dpkg/status"

  type apt_cache_entry = {
    version : string;
    machine : string;
    size : Int64.t option;
  }

  let debian_distribution ?(status_file=dpkg_db_status) config =
    let apt_cache = Hashtbl.create 10 in
    let system = config.system in

    (* Populate [apt_cache] with the results. *)
    let query_apt_cache package_names =
      package_names |> Lwt_list.iter_s (fun package ->
        (* Check to see whether we could get a newer version using apt-get *)
        lwt result =
          try_lwt
            lwt out = Lwt_process.pread ~stderr:`Dev_null (U.make_command system ["apt-cache"; "show"; "--no-all-versions"; "--"; package]) in
            let machine = ref None in
            let version = ref None in
            let size = ref None in
            let stream = U.stream_of_lines out in
            begin try
              while true do
                let line = Stream.next stream |> trim in
                if U.starts_with line "Version: " then (
                  version := try_cleanup_distro_version_warn (U.string_tail line 9 |> trim) package
                ) else if U.starts_with line "Architecture: " then (
                  machine := Some (Support.System.canonical_machine (U.string_tail line 14 |> trim))
                ) else if U.starts_with line "Size: " then (
                  size := Some (Int64.of_string (U.string_tail line 6 |> trim))
                )
              done
            with Stream.Failure -> () end;
            match !version, !machine with
            | Some version, Some machine -> Lwt.return (Some {version; machine; size = !size})
            | _ -> Lwt.return None
          with ex ->
            log_warning ~ex "'apt-cache show %s' failed" package;
            Lwt.return None in
        (* (multi-arch support? can there be multiple candidates?) *)
        Hashtbl.replace apt_cache package result;
        Lwt.return ()
      ) in

    (* Returns information about this package, or ["-"] if it's not installed. *)
    let query_dpkg package_name =
      let results = ref [] in
      U.finally_do Unix.close (Unix.openfile Support.System.dev_null [Unix.O_WRONLY] 0)
        (fun dev_null ->
          ["dpkg-query"; "-W"; "--showformat=${Version}\t${Architecture}\t${Status}\n"; "--"; package_name]
            |> U.check_output ~stderr:(`FD dev_null) system (fun ch  ->
              try
                while true do
                  let line = input_line ch in
                  match Str.bounded_split_delim U.re_tab line 3 with
                  | [] -> ()
                  | [version; debarch; status] ->
                      if U.ends_with status " installed" then (
                        let debarch =
                          try U.string_tail debarch (String.rindex debarch '-' + 1)
                          with Not_found -> debarch in
                        match try_cleanup_distro_version_warn version package_name with
                        | None -> ()
                        | Some clean_version ->
                            let r = Printf.sprintf "%s\t%s" clean_version (Support.System.canonical_machine (trim debarch)) in
                            results := r :: !results
                      )
                  | _ -> log_warning "Can't parse dpkg output: '%s'" line
                done
              with End_of_file -> ()
            )
        );
      if !results = [] then ["-"] else !results in

    let fixup_java_main impl java_version =
      let java_arch = if impl.Feed.machine = Some "x86_64" then Some "amd64" else impl.Feed.machine in

      match java_arch with
      | None -> log_warning "BUG: Missing machine type on Java!"; None
      | Some java_arch ->
          let java_bin = Printf.sprintf "/usr/lib/jvm/java-%s-%s/jre/bin/java" java_version java_arch in
          if system#file_exists java_bin then Some java_bin
          else (
            (* Try without the arch... *)
            let java_bin = Printf.sprintf "/usr/lib/jvm/java-%s/jre/bin/java" java_version in
            if system#file_exists java_bin then Some java_bin
            else (
              log_info "Java binary not found (%s)" java_bin;
              Some "/usr/bin/java"
            )
          ) in

    object (self : #Distro.distribution)
      inherit Distro.distribution config as super
      val check_host_python = false

      val distro_name = "Debian"
      val id_prefix = "package:deb"
      val cache = new Cache.cache config "dpkg-status.cache" status_file 2 ~old_format:false

      method! is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem

      method! private get_package_impls query =
        (* Add any PackageKit candidates *)
        super#get_package_impls query;

        (* Add apt-cache candidates (there won't be any if we used PackageKit) *)
        let package_name = query#package_name in
        let entry = try Hashtbl.find apt_cache package_name with Not_found -> None in
        entry |> if_some (fun {version; machine; size = _} ->
          let id = Printf.sprintf "package:deb:%s:%s:%s" package_name version machine in
          let machine = Arch.none_if_star machine in
          self#add_package_implementation ~is_installed:false ~id ~version ~machine ~extra_attrs:[] ~distro_name query
        );

        (* If our dpkg cache is up-to-date, add from there. Otherwise, add from Python. *)
        match cache#get ~if_missing:query_dpkg package_name with
        | ["-"] -> ()                         (* We know the package isn't installed *)
        | infos ->
            infos |> List.iter (fun cached_info ->
              match Str.split_delim U.re_tab cached_info with
              | [version; machine] ->
                  let id = Printf.sprintf "%s:%s:%s:%s" id_prefix package_name version machine in
                  let machine = Arch.none_if_star machine in
                  self#add_package_implementation ~is_installed:true ~id ~version ~machine ~extra_attrs:[] ~distro_name query
              | _ ->
                  log_warning "Unknown cache line format for '%s': %s" package_name cached_info
            )

      method! check_for_candidates feed =
        match Distro.get_matching_package_impls self feed with
        | [] -> Lwt.return ()
        | matches ->
            lwt available = packagekit#is_available in
            if available then (
              let package_names = matches |> List.map (fun (elem, _props) -> ZI.get_attribute "package" elem) in
              packagekit#check_for_candidates package_names
            ) else (
              (* No PackageKit. Use apt-cache directly. *)
              query_apt_cache (matches |> List.map (fun (elem, _props) -> (ZI.get_attribute "package" elem)))
            )

      method! private add_package_implementation ?main ?retrieval_method query ~id ~version ~machine ~extra_attrs ~is_installed ~distro_name =
        let version =
          if U.starts_with id "package:deb:openjdk-6-jre:" ||
             U.starts_with id "package:deb:openjdk-7-jre:" then (
            (* Debian marks all Java versions as pre-releases
               See: http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=685276 *)
            Str.replace_first (Str.regexp_string "-pre") "." version
          ) else version in
        super#add_package_implementation ?main ?retrieval_method query ~id ~version ~machine ~extra_attrs ~is_installed ~distro_name

      method! private get_correct_main impl run_command =
        let id = Feed.get_attr_ex Constants.FeedAttr.id impl in
        if U.starts_with id "package:deb:openjdk-6-jre:" then
          fixup_java_main impl "6-openjdk"
        else if U.starts_with id "package:deb:openjdk-7-jre:" then
          fixup_java_main impl "7-openjdk"
        else
          super#get_correct_main impl run_command
    end
end

module RPM = struct
  let rpm_db_packages = "/var/lib/rpm/Packages"

  let rpm_distribution ?(status_file = rpm_db_packages) config slave =
    object
      inherit Distro.python_fallback_distribution slave "RPMDistribution" [status_file] as super
      val check_host_python = false

      val distro_name = "RPM"
      val id_prefix = "package:rpm"
      val cache = new Cache.cache config "rpm-status.cache" rpm_db_packages 2 ~old_format:true

      method! is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem
    end
end

module ArchLinux = struct
  let arch_db = "/var/lib/pacman"

  let arch_distribution ?(arch_db=arch_db) config =
    let packages_dir = arch_db ^ "/local" in
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

    object (self : #Distro.distribution)
      inherit Distro.distribution config as super
      val check_host_python = false

      val distro_name = "Arch"
      val id_prefix = "package:arch"

      (* We should never get here for an installed package, because we always set quick-test-* *)
      method! is_installed _elem = false

      method! private get_package_impls query =
        (* Start with impls from PackageKit *)
        super#get_package_impls query;

        (* Check the local package database *)
        let package_name = query#package_name in
        log_debug "Looking up distribution packages for %s" package_name;
        let items = get_entries () in
        match StringMap.find package_name items with
        | None -> ()
        | Some version ->
            let entry = package_name ^ "-" ^ version in
            let desc_path = packages_dir +/ entry +/ "desc" in
            match get_arch desc_path with
            | None ->
                log_warning "No ARCH in %s" desc_path
            | Some arch ->
                let machine = Support.System.canonical_machine arch in
                match try_cleanup_distro_version_warn version package_name with
                | None -> ()
                | Some version ->
                    let id = Printf.sprintf "%s:%s:%s:%s" id_prefix package_name version machine in
                    let machine = Arch.none_if_star machine in
                    self#add_package_implementation ~is_installed:true ~id ~version ~machine ~extra_attrs:[("quick-test-file", desc_path)] ~distro_name query
    end
end

module Mac = struct
  let macports_db = "/opt/local/var/macports/registry/registry.db"

  (* Note: we currently don't have or need DarwinDistribution, because that uses quick-test-* attributes *)

  let macports_distribution ?(macports_db=macports_db) config slave =
    object
      inherit Distro.python_fallback_distribution slave "MacPortsDistribution" [macports_db] as super
      val check_host_python = true

      val! system_paths = ["/opt/local/bin"]

      val distro_name = "MacPorts"
      val id_prefix = "package:macports"
      val cache = new Cache.cache config "macports-status.cache" macports_db 2 ~old_format:true

      method! is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem

      method! match_name name = (name = distro_name || name = "Darwin")
    end

  let darwin_distribution _config slave =
    object
      inherit Distro.python_fallback_distribution slave "DarwinDistribution" []
      val check_host_python = true
      val distro_name = "Darwin"
      val id_prefix = "package:darwin"
    end
end

module Win = struct
  let windows_distribution _config slave =
    object
      inherit Distro.python_fallback_distribution slave "WindowsDistribution" [] as super
      val check_host_python = false (* (0install's bundled Python may not be generally usable) *)

      val! system_paths = []

      val distro_name = "Windows"
      val id_prefix = "package:windows"

      method! private add_package_impls_from_python query =
        let package_name = query#package_name in
        match package_name with
        | "openjdk-6-jre" | "openjdk-6-jdk"
        | "openjdk-7-jre" | "openjdk-7-jdk"
        | "netfx" | "netfx-client" ->
            Qdom.log_elem Support.Logging.Info "FIXME: Windows: can't check for package '%s':" package_name query#elem;
            super#add_package_impls_from_python query
        | _ -> ()

        (* No PackageKit support on Windows *)
      method! check_for_candidates _feed = Lwt.return ()
    end

  let cygwin_log = "/var/log/setup.log"

  let cygwin_distribution config slave =
    object
      inherit Distro.python_fallback_distribution slave "CygwinDistribution" ["/var/log/setup.log"] as super
      val check_host_python = false (* (0install's bundled Python may not be generally usable) *)

      val distro_name = "Cygwin"
      val id_prefix = "package:cygwin"
      val cache = new Cache.cache config "cygcheck-status.cache" cygwin_log 2 ~old_format:true

      method! is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem
    end
end

module Ports = struct
  let pkg_db = "/var/db/pkg"

  let ports_distribution ?(pkgdir=pkg_db) _config slave =
    object
      inherit Distro.python_fallback_distribution slave "PortsDistribution" [pkgdir]
      val check_host_python = true
      val id_prefix = "package:ports"
      val distro_name = "Ports"
    end
end

module Gentoo = struct
  let gentoo_distribution ?(pkgdir=Ports.pkg_db) _config slave =
    object
      inherit Distro.python_fallback_distribution slave "GentooDistribution" [pkgdir]
      val check_host_python = false
      val distro_name = "Gentoo"
      val id_prefix = "package:gentoo"
    end
end

module Slackware = struct
  let slack_db = "/var/log/packages"

  let slack_distribution ?(packages_dir=slack_db) _config slave =
    object
      inherit Distro.python_fallback_distribution slave "SlackDistribution" [packages_dir]
      val check_host_python = false
      val distro_name = "Slack"
      val id_prefix = "package:slack"
    end
end

let get_host_distribution config (slave:Python.slave) : Distro.distribution =
  let x = Sys.file_exists in

  match Sys.os_type with
  | "Unix" ->
      let is_debian =
        match config.system#stat Debian.dpkg_db_status with
        | Some info when info.Unix.st_size > 0 -> true
        | _ -> false in

      if is_debian then
        Debian.debian_distribution config
      else if x ArchLinux.arch_db then
        ArchLinux.arch_distribution config
      else if x RPM.rpm_db_packages then
        RPM.rpm_distribution config slave
      else if x Mac.macports_db then
        Mac.macports_distribution config slave
      else if x Ports.pkg_db then (
        if config.system#platform.Platform.os = "Linux" then
          Gentoo.gentoo_distribution config slave
        else
          Ports.ports_distribution config slave
      ) else if x Slackware.slack_db then
        Slackware.slack_distribution config slave
      else if config.system#platform.Platform.os = "Darwin" then
        Mac.darwin_distribution config slave
      else
        generic_distribution slave
  | "Win32" -> Win.windows_distribution config slave
  | "Cygwin" -> Win.cygwin_distribution config slave
  | _ ->
      generic_distribution slave
