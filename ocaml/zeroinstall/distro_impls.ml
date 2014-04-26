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

open Distro

let generic_distribution config =
  object
    inherit Distro.distribution config
    val check_host_python = true
    val distro_name = "fallback"
    val id_prefix = "package:fallback"
  end

let try_cleanup_distro_version_warn version package_name =
  match Versions.try_cleanup_distro_version version with
  | None -> log_warning "Can't parse distribution version '%s' for package '%s'" version package_name; None
  | Some zi_version -> Some zi_version

let iter_dir system fn path =
  match system#readdir path with
  | Problem ex when U.is_dir system path -> raise ex
  | Problem ex -> log_debug ~ex "Failed to read directory '%s'" path
  | Success items -> items |> Array.iter fn

(** Lookup [elem]'s package in the cache. Generate the ID(s) for the cached implementations and check that one of them
    matches the [id] attribute on [elem].
    Returns [false] if the cache is out-of-date. *)
let check_cache id_prefix elem (cache:Distro_cache.cache) =
  match ZI.get_attribute_opt "package" elem with
  | None ->
      Qdom.log_elem Support.Logging.Warning "Missing 'package' attribute" elem;
      false
  | Some package ->
      let sel_id = ZI.get_attribute "id" elem in
      let matches (installed_version, machine) =
        let installed_id = Printf.sprintf "%s:%s:%s:%s" id_prefix package (Versions.format_version installed_version) (default "*" machine) in
        (* log_warning "Want %s %s, have %s" package sel_id installed_id; *)
        sel_id = installed_id in
      List.exists matches (fst (cache#get package))

module Debian = struct
  let dpkg_db_status = "/var/lib/dpkg/status"

  (* It's OK if dpkg-query returns a non-zero exit status. *)
  let error_ok child_pid =
    match snd (Support.System.waitpid_non_intr child_pid) with
    | Unix.WEXITED _ -> ()
    | status -> Support.System.check_exit_status status

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
            | Some version, Some machine -> Lwt.return (Some {version = Versions.format_version version; machine; size = !size})
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
            |> U.check_output ~reaper:error_ok ~stderr:(`FD dev_null) system (fun ch  ->
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
                            let r = (clean_version, (Arch.none_if_star (Support.System.canonical_machine (trim debarch)))) in
                            results := r :: !results
                      )
                  | _ -> log_warning "Can't parse dpkg output: '%s'" line
                done
              with End_of_file -> ()
            )
        );
      !results in

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
      val cache = new Distro_cache.cache config ~cache_leaf:"dpkg-status2.cache" status_file

      method! is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem

      method! private get_package_impls query =
        (* Add any PackageKit candidates *)
        super#get_package_impls query;

        (* Add apt-cache candidates (there won't be any if we used PackageKit) *)
        let package_name = query.package_name in
        let entry = try Hashtbl.find apt_cache package_name with Not_found -> None in
        entry |> if_some (fun {version; machine; size = _} ->
          let version = Versions.parse_version version in
          let machine = Arch.none_if_star machine in
          let package_state = `uninstalled Feed.({distro_size = None; distro_install_info = ("apt-get install", package_name)}) in
          self#add_package_implementation ~package_state ~version ~machine ~quick_test:None ~distro_name query
        );

        (* Add installed packages by querying dpkg. *)
        let infos, quick_test = cache#get ~if_missing:query_dpkg package_name in
        infos |> List.iter (fun (version, machine) ->
          self#add_package_implementation ~package_state:`installed ~version ~machine ~quick_test ~distro_name query
        )

      method! check_for_candidates ~ui feed =
        match Distro.get_matching_package_impls self feed with
        | [] -> Lwt.return ()
        | matches ->
            lwt available = packagekit#is_available in
            if available then (
              let package_names = matches |> List.map (fun (elem, _props) -> ZI.get_attribute "package" elem) in
              let hint = Feed_url.format_url feed.Feed.url in
              packagekit#check_for_candidates ~ui ~hint package_names
            ) else (
              (* No PackageKit. Use apt-cache directly. *)
              query_apt_cache (matches |> List.map (fun (elem, _props) -> (ZI.get_attribute "package" elem)))
            )

      method! private add_package_implementation ?id ?main query ~version ~machine ~quick_test ~package_state ~distro_name =
        let version =
          match query.package_name, version with
          | ("openjdk-6-jre" | "openjdk-7-jre"), (([major], Versions.Pre) :: (minor, mmod) :: rest) ->
            (* Debian marks all Java versions as pre-releases
               See: http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=685276 *)
            (major :: minor, mmod) :: rest
          | _ -> version in

        super#add_package_implementation ?id ?main query ~version ~machine ~quick_test ~package_state ~distro_name

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

  let rpm_distribution ?(rpm_db_packages = rpm_db_packages) config =
    let fixup_java_main impl java_version =
      (* (note: on Fedora, unlike Debian, the arch is x86_64, not amd64) *)

      match impl.Feed.machine with
      | None -> log_warning "BUG: Missing machine type on Java!"; None
      | Some java_arch ->
          let java_bin = Printf.sprintf "/usr/lib/jvm/jre-%s.%s/bin/java" java_version java_arch in
          if config.system#file_exists java_bin then Some java_bin
          else (
            (* Try without the arch... *)
            let java_bin = Printf.sprintf "/usr/lib/jvm/jre-%s/bin/java" java_version in
            if config.system#file_exists java_bin then Some java_bin
            else (
              log_info "Java binary not found (%s)" java_bin;
              Some "/usr/bin/java"
            )
          ) in

    object (self)
      inherit Distro.distribution config as super
      val check_host_python = false

      val distro_name = "RPM"
      val id_prefix = "package:rpm"
      val cache =
        object
          inherit Distro_cache.cache config ~cache_leaf:"rpm-status3.cache" rpm_db_packages
          method! private regenerate_cache add_entry =
            ["rpm"; "-qa"; "--qf=%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n"]
              |> U.check_output config.system (fun from_rpm  ->
                try
                  while true do
                    let line = input_line from_rpm in
                    match Str.bounded_split_delim U.re_tab line 3 with
                    | ["gpg-pubkey"; _; _] -> ()
                    | [package; version; rpmarch] ->
                        let zi_arch = Support.System.canonical_machine (trim rpmarch) |> Arch.none_if_star in
                        try_cleanup_distro_version_warn version package |> if_some (fun clean_version ->
                          add_entry package (clean_version, zi_arch)
                        )
                    | _ -> log_warning "Invalid output from 'rpm': %s" line
                  done
                with End_of_file -> ()
              )
        end

      method! private get_package_impls query =
        (* Add any PackageKit candidates *)
        super#get_package_impls query;

        (* Add installed packages by querying rpm *)
        let infos, quick_test = cache#get query.package_name in
        infos |> List.iter (fun (version, machine) ->
          self#add_package_implementation ~package_state:`installed ~version ~machine ~quick_test ~distro_name query
        )

      method! is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem

      method! private get_correct_main impl run_command =
        (* OpenSUSE uses _, Fedora uses . *)
        let id = Feed.get_attr_ex Constants.FeedAttr.id impl in
        let starts x = U.starts_with id x in
        if starts "package:rpm:java-1.6.0-openjdk:" || starts "package:rpm:java-1_6_0-openjdk:" then
          fixup_java_main impl "1.6.0-openjdk"
        else if starts "package:rpm:java-1.7.0-openjdk:" || starts "package:rpm:java-1_7_0-openjdk:" then
          fixup_java_main impl "1.7.0-openjdk"
        else
          super#get_correct_main impl run_command

      method! private add_package_implementation ?id ?main query ~version ~machine ~quick_test ~package_state ~distro_name =
        let version =
          (* OpenSUSE uses _, Fedora uses . *)
          let package_name = String.copy query.package_name in
          for i = 0 to String.length package_name - 1 do
            if package_name.[i] = '_' then package_name.[i] <- '.'
          done;
          match package_name with
          | "java-1.6.0-openjdk" | "java-1.7.0-openjdk"
          | "java-1.6.0-openjdk-devel" | "java-1.7.0-openjdk-devel" ->
              (* OpenSUSE uses 1.6 to mean 6 *)
              begin match version with
              | (1L :: major, mmod) :: rest -> (major, mmod) :: rest
              | _ -> version end;
          | _ -> version in

        super#add_package_implementation ?id ?main query ~version ~machine ~quick_test ~package_state ~distro_name
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
      desc_path |> config.system#with_open_in [Open_rdonly; Open_text] (fun ch ->
        try
          while !arch = None do
            let line = input_line ch in
            if line = "%ARCH%" then
              arch := Some (trim (input_line ch))
          done
        with End_of_file -> ()
      );
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

      method! private get_package_impls query =
        (* Start with impls from PackageKit *)
        super#get_package_impls query;

        (* Check the local package database *)
        let package_name = query.package_name in
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
                    let machine = Arch.none_if_star machine in
                    let quick_test = Some (desc_path, Exists) in
                    self#add_package_implementation ~package_state:`installed ~version ~machine ~quick_test ~distro_name query
    end
end

module Mac = struct
  let macports_db = "/opt/local/var/macports/registry/registry.db"

  let darwin_distribution config =
    let get_version main =
      let first_line = [main; "--version"] |> U.check_output config.system input_line in
      try
        let i = String.rindex first_line ' ' in
        U.string_tail first_line (i + 1)
      with Not_found -> first_line in

    let java_home version arch =
      U.finally_do Unix.close (Unix.openfile Support.System.dev_null [Unix.O_WRONLY] 0)
        (fun dev_null ->
          let command = ["/usr/libexec/java_home"; "--failfast"; "--version"; version; "--arch"; arch] in
          trim (try command |> U.check_output config.system ~stderr:(`FD dev_null) input_line with End_of_file -> "")
        ) in

    object (self : #distribution)
      inherit Distro.distribution config as super
      val distro_name = "Darwin"
      val id_prefix = "package:darwin"
      val check_host_python = true

      method! private get_package_impls query =
        match query.package_name with
        | "openjdk-6-jre" | "openjdk-6-jdk" -> self#find_java "1.6" "6" query
        | "openjdk-7-jre" | "openjdk-7-jdk" -> self#find_java "1.7" "7" query
        | "gnupg" -> self#find_program "/usr/local/bin/gpg" query
        | "gnupg2" -> self#find_program "/usr/local/bin/gpg2" query
        | _ -> super#get_package_impls query

      method private find_program main query =
        config.system#stat main |> if_some (fun info ->
          let x_ok = try Unix.access main [Unix.X_OK]; true with Unix.Unix_error _ -> false in
          if x_ok then (
            try_cleanup_distro_version_warn (get_version main) query.package_name |> if_some (fun version ->
              self#add_package_implementation
                ~main
                ~package_state:`installed
                ~version
                ~machine:(Some config.system#platform.Platform.machine)
                ~quick_test:(Some (main, UnchangedSince info.Unix.st_mtime))
                ~distro_name
                query
            )
          )
        )

      method private find_java jvm_version zero_version query =
        ["i386"; "x86_64"] |> List.iter (fun machine ->
          let home = java_home jvm_version machine in
          let main = home +/ "bin/java" in
          match config.system#stat main with
          | Some info ->
              self#add_package_implementation
                ~main
                ~package_state:`installed
                ~version:(Versions.parse_version zero_version)
                ~machine:(Some machine)
                ~quick_test:(Some (main, UnchangedSince info.Unix.st_mtime))
                ~distro_name
                query
          | None -> ()
        )
    end

  let macports_distribution ?(macports_db=macports_db) config =
    let re_version = Str.regexp "^@*\\([^+]+\\)\\(\\+.*\\)?$" in (* strip variants *)
    let re_extra = Str.regexp " platform='\\([^' ]*\\)\\( [0-9]+\\)?' archs='\\([^']*\\)'" in
    object (self : #distribution)
      inherit Distro.distribution config as super

      val! system_paths = ["/opt/local/bin"]
      val darwin = darwin_distribution config
      val check_host_python = false     (* Darwin will do it *)

      val distro_name = "MacPorts"
      val id_prefix = "package:macports"
      val cache =
        object
          inherit Distro_cache.cache config ~cache_leaf:"macports-status2.cache" macports_db

          method! private regenerate_cache add_entry =
            ["port"; "-v"; "installed"] |> U.check_output config.system (fun ch ->
              try
                while true do
                  let line = input_line ch in
                  log_debug "Got: '%s'" line;
                  if U.starts_with line " " then (
                    let line = trim line in
                    match Str.bounded_split_delim U.re_space line 3 with
                    | [package; version; extra] when U.starts_with extra "(active)" ->
                        log_debug "Found package='%s' version='%s' extra='%s'" package version extra;
                        if Str.string_match re_version version 0 then (
                          let version = Str.matched_group 1 version in
                          try_cleanup_distro_version_warn version package |> if_some (fun version ->
                            if Str.string_match re_extra extra 0 then (
                              (* let platform = Str.matched_group 1 extra in *)
                              (* let major = Str.matched_group 2 extra in *)
                              let archs = Str.matched_group 3 extra in
                              Str.split U.re_space archs |> List.iter (fun arch ->
                                let zi_arch = Support.System.canonical_machine arch in
                                add_entry package (version, Arch.none_if_star zi_arch)
                              )
                            ) else (
                              add_entry package (version, None)
                            )
                          )
                        ) else log_debug "Failed to match version '%s'" version
                    | [_package; _version; _extra] -> ()
                    | [_package; _version] -> ()
                    | _ -> raise_safe "Invalid port output: '%s'" line
                  )
                done
              with End_of_file -> ()
            )
        end

      method! is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem

      method! match_name name = super#match_name name || darwin#match_name name

      method! get_impls_for_feed ?init feed =
        let ports = super#get_impls_for_feed ?init feed in
        darwin#get_impls_for_feed ~init:ports feed

      method! private get_package_impls query =
        super#get_package_impls query;

        let infos, quick_test = cache#get query.package_name in
        infos |> List.iter (fun (version, machine) ->
          self#add_package_implementation ~package_state:`installed ~version ~machine ~quick_test ~distro_name query
        )
    end

end

module Win = struct
  let windows_distribution config =
    let api = !Support.Windows_api.windowsAPI |? lazy (raise_safe "Failed to load Windows support module!") in

    let read_hklm_reg reader =
      let open Support.Windows_api in
      match config.system#platform.Platform.machine with
      | "x86_64" ->
          let value32 = reader KEY_WOW64_32KEY in
          let value64 = reader KEY_WOW64_64KEY in
          (value32, value64)
      | _ ->
          let value32 = reader KEY_WOW64_NONE in
          (value32, None) in

    object (self)
      inherit Distro.distribution config as super
      val check_host_python = false (* (0install's bundled Python may not be generally usable) *)

      val! system_paths = []

      val distro_name = "Windows"
      val id_prefix = "package:windows"

      method! private get_package_impls query =
        super#get_package_impls query;

        let package_name = query.package_name in
        match package_name with
        | "openjdk-6-jre" -> self#find_java "Java Runtime Environment" "1.6" "6" query
        | "openjdk-6-jdk" -> self#find_java "Java Development Kit"     "1.6" "6" query
        | "openjdk-7-jre" -> self#find_java "Java Runtime Environment" "1.7" "7" query
        | "openjdk-7-jdk" -> self#find_java "Java Development Kit"     "1.7" "7" query
        | "netfx" ->
            self#find_netfx "v2.0.50727" "2.0" query;
            self#find_netfx "v3.0"       "3.0" query;
            self#find_netfx "v3.5"       "3.5" query;
            self#find_netfx "v4\\Full"   "4.0" query;
            self#find_netfx_release "v4\\Full" 378389 "4.5" query;
            self#find_netfx "v5" "5.0" query;
        | "netfx-client" ->
            self#find_netfx "v4\\Client" "4.0" query;
            self#find_netfx_release "v4\\Client" 378389 "4.5" query;
        | _ -> ()

        (* No PackageKit support on Windows *)
      method! check_for_candidates ~ui:_ _feed = Lwt.return ()

      method private find_netfx win_version zero_version query =
        let reg_path = "SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\" ^ win_version in
        let netfx32_install, netfx64_install = read_hklm_reg (api#read_registry_int reg_path "Install") in

        [(netfx32_install, "i486"); (netfx64_install, "x86_64")] |> List.iter (function
          | None, _ -> ()
          | Some install, machine ->
              let version = Versions.parse_version zero_version in
              let package_state =
                if install = 1 then `installed
                else `uninstalled Feed.({distro_size = None; distro_install_info = ("Windows installer", "NetFX")}) in
              self#add_package_implementation
                ~main:""      (* .NET executables do not need a runner on Windows but they need one elsewhere *)
                ~package_state
                ~version
                ~machine:(Some machine)
                ~quick_test:None
                ~distro_name
                query
        )

      method private find_netfx_release win_version release_version zero_version query =
        let reg_path = "SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\" ^ win_version in
        let netfx32_install, netfx64_install = read_hklm_reg (api#read_registry_int reg_path "Install") in
        let netfx32_release, netfx64_release = read_hklm_reg (api#read_registry_int reg_path "Release") in

        [(netfx32_install, netfx32_release, "i486"); (netfx64_install, netfx64_release, "x86_64")] |> List.iter (function
          | Some install, Some release, machine ->
              let version = Versions.parse_version zero_version in
              let package_state =
                if install = 1 && release >= release_version then `installed
                else `uninstalled Feed.({distro_size = None; distro_install_info = ("Windows installer", "NetFX")}) in
              self#add_package_implementation
                ~main:""      (* .NET executables do not need a runner on Windows but they need one elsewhere *)
                ~package_state
                ~version
                ~machine:(Some machine)
                ~quick_test:None
                ~distro_name
                query
          | _ -> ()
        )

      method private find_java part win_version zero_version query =
        let reg_path = Printf.sprintf "SOFTWARE\\JavaSoft\\%s\\%s" part win_version in
        let java32_home, java64_home = read_hklm_reg (api#read_registry_string reg_path "JavaHome") in

        [(java32_home, "i486"); (java64_home, "x86_64")] |> List.iter (function
          | None, _ -> ()
          | Some home, machine ->
              let java_bin = home +/ "bin\\java.exe" in
              match config.system#stat java_bin with
              | None -> ()
              | Some info ->
                  let version = Versions.parse_version zero_version in
                  let quick_test = Some (java_bin, UnchangedSince info.Unix.st_mtime) in
                  self#add_package_implementation
                    ~main:java_bin
                    ~package_state:`installed
                    ~version
                    ~machine:(Some machine)
                    ~quick_test
                    ~distro_name
                    query
        )
    end

  let cygwin_log = "/var/log/setup.log"

  (* Note: this is ported from the Python but completely untested. *)
  let cygwin_distribution config =
    let re_whitespace = Str.regexp "[ \t]+" in
    object (self)
      inherit Distro.distribution config as super
      val distro_name = "Cygwin"
      val id_prefix = "package:cygwin"
      val check_host_python = false

      val cache =
        object
          inherit Distro_cache.cache config ~cache_leaf:"cygcheck-status2.cache" cygwin_log
          method! private regenerate_cache add_entry =
            ["cygcheck"; "-c"; "-d"] |> U.check_output config.system (fun from_cyg  ->
                try
                  while true do
                    match input_line from_cyg with
                    | "Cygwin Package Information" | "" -> ()
                    | line ->
                        match U.split_pair re_whitespace line with
                        | ("Package", "Version") -> ()
                        | (package, version) ->
                            try_cleanup_distro_version_warn version package |> if_some (fun clean_version ->
                              add_entry package (clean_version, None)
                            )
                  done
                with End_of_file -> ()
              )
        end

      method! is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem

      method! private get_package_impls query =
        let infos, quick_test = cache#get query.package_name in
        infos |> List.iter (fun (version, machine) ->
          self#add_package_implementation ~package_state:`installed ~version ~machine ~quick_test ~distro_name query
        )
    end
end

module Ports = struct
  let pkg_db = "/var/db/pkg"

  let ports_distribution ?(pkg_db=pkg_db) config =
    let re_name_version = Str.regexp "^\\(.+\\)-\\([^-]+\\)$" in

    object (self)
      inherit Distro.distribution config
      val id_prefix = "package:ports"
      val distro_name = "Ports"
      val check_host_python = true

      method! private get_package_impls query =
        pkg_db |> iter_dir config.system (fun pkgname ->
          let pkgdir = pkg_db +/ pkgname in
          if U.is_dir config.system pkgdir then (
            if Str.string_match re_name_version pkgname 0 then (
              let name = Str.matched_group 1 pkgname in
              let version = Str.matched_group 2 pkgname in
              if name = query.package_name then (
                try_cleanup_distro_version_warn version query.package_name |> if_some (fun version ->
                  let machine = Some config.system#platform.Platform.machine in
                  self#add_package_implementation
                    ~package_state:`installed
                    ~version
                    ~machine
                    ~quick_test:None
                    ~distro_name
                    query
                )
              )
            ) else (
              log_warning "Cannot parse version from Ports package named '%s'" pkgname
            )
          )
        )
    end
end

module Gentoo = struct
  let is_digit = function
    | '0' .. '9' -> true
    | _ -> false

  let gentoo_distribution ?(pkgdir=Ports.pkg_db) config =
    object (self)
      inherit Distro.distribution config
      val! valid_package_name = Str.regexp "^[^.-][^/]*/[^./][^/]*$"
      val distro_name = "Gentoo"
      val id_prefix = "package:gentoo"
      val check_host_python = false

      method! private get_package_impls query =
        let re_version_start = Str.regexp "-[0-9]" in

        match Str.bounded_split_delim U.re_slash query.package_name 2 with
        | [category; leafname] ->
            let category_dir = pkgdir +/ category in
            let match_prefix = leafname ^ "-" in

            category_dir |> iter_dir config.system (fun filename ->
              if U.starts_with filename match_prefix && is_digit (filename.[String.length match_prefix]) then (
                let pf_path = category_dir +/ filename +/ "PF"in
                let pf_mtime = (config.system#lstat pf_path |? lazy (raise_safe "Missing '%s' file!" pf_path)).Unix.st_mtime in
                let name = pf_path|> config.system#with_open_in [Open_rdonly] input_line |> trim in

                match (try Some (Str.search_forward re_version_start name 0) with Not_found -> None) with
                | None -> log_warning "Cannot parse version from Gentoo package named '%s'" name
                | Some i ->
                  try_cleanup_distro_version_warn (U.string_tail name (i + 1)) query.package_name |> if_some (fun version ->
                    let machine =
                      if category = "app-emulation" && U.starts_with name "emul-" then (
                        match Str.bounded_split_delim U.re_dash name 4 with
                        | [_; _; machine; _] -> machine
                        | _ -> "*"
                      ) else (
                        category_dir +/ filename +/ "CHOST" |> config.system#with_open_in [Open_rdonly] (fun ch ->
                          input_line ch |> U.split_pair U.re_dash |> fst
                        )
                      ) in
                    let machine = Arch.none_if_star (Support.System.canonical_machine machine) in
                    self#add_package_implementation
                      ~package_state:`installed
                      ~version
                      ~machine
                      ~quick_test:(Some (pf_path, UnchangedSince pf_mtime))
                      ~distro_name
                      query
                  )
              )
            )
        | _ -> ()
    end
end

module Slackware = struct
  let slack_db = "/var/log/packages"

  let slack_distribution ?(packages_dir=slack_db) config =
    object (self)
      inherit Distro.distribution config
      val distro_name = "Slack"
      val id_prefix = "package:slack"
      val check_host_python = false

      method! private get_package_impls query =
        packages_dir |> iter_dir config.system (fun entry ->
          match Str.bounded_split_delim U.re_dash entry 4 with
          | [name; version; arch; build] when name = query.package_name ->
              let machine = Arch.none_if_star (Support.System.canonical_machine arch) in
              try_cleanup_distro_version_warn (version ^ "-" ^ build) query.package_name |> if_some (fun version ->
              self#add_package_implementation
                ~package_state:`installed
                ~version
                ~machine
                ~quick_test:(Some (packages_dir +/ entry, Exists))
                ~distro_name
                query
              )
          | _ -> ()
        )
    end
end

let get_host_distribution config : Distro.distribution =
  let exists = config.system#file_exists in

  match Sys.os_type with
  | "Unix" ->
      let is_debian =
        match config.system#stat Debian.dpkg_db_status with
        | Some info when info.Unix.st_size > 0 -> true
        | _ -> false in

      if is_debian then
        Debian.debian_distribution config
      else if exists ArchLinux.arch_db then
        ArchLinux.arch_distribution config
      else if exists RPM.rpm_db_packages then
        RPM.rpm_distribution config
      else if exists Mac.macports_db then
        Mac.macports_distribution config
      else if exists Ports.pkg_db then (
        if config.system#platform.Platform.os = "Linux" then
          Gentoo.gentoo_distribution config
        else
          Ports.ports_distribution config
      ) else if exists Slackware.slack_db then
        Slackware.slack_distribution config
      else if config.system#platform.Platform.os = "Darwin" then
        Mac.darwin_distribution config
      else
        generic_distribution config
  | "Win32" -> Win.windows_distribution config
  | "Cygwin" -> Win.cygwin_distribution config
  | _ ->
      generic_distribution config
