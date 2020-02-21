(* Copyright (C) 2017, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interacting with distribution package managers. *)

open General
open Support
open Support.Common
module U = Support.Utils

open Distro

let with_simple_progress fn =
  let progress, set_progress = Lwt_react.S.create (Int64.zero, None, false) in
  Lwt.finalize
    (fun () -> fn progress)
    (fun () ->
       set_progress (Int64.zero, None, true);
       Lwt.return ()
    )

(** Base class for platforms that can use PackageKit *)
class virtual packagekit_distro ~(packagekit:Packagekit.packagekit Lazy.t) config =
  object (self)
    inherit distribution config

    method private get_package_impls query =
      let packagekit = Lazy.force packagekit in
      let package_name = Query.package query in
      let pk_unavailable reason = Query.problem query "%s: %s" package_name reason in
      match Lwt.state packagekit#status with
      | Lwt.Fail ex -> pk_unavailable (Printexc.to_string ex)
      | Lwt.Sleep -> pk_unavailable "Waiting for PackageKit..."
      | Lwt.Return (`Unavailable reason) -> pk_unavailable reason
      | Lwt.Return `Ok ->
          let pk_query = packagekit#get_impls package_name in
          pk_query.Packagekit.problems |> List.iter (fun x -> Query.problem query "%s" x);
          pk_query.Packagekit.results |> List.iter (fun info ->
            let {Packagekit.version; machine; installed; retrieval_method} = info in
            let package_state =
              if installed then `Installed
              else `Uninstalled retrieval_method in
            self#add_package_implementation
              ~version
              ~machine
              ~package_state
              ~quick_test:None
              ~distro_name:distro_name
              query
          )

    (* This default implementation queries PackageKit, if available. *)
    method check_for_candidates ~ui feed =
      let packagekit = Lazy.force packagekit in
      match get_matching_package_impls self feed with
      | [] -> Lwt.return ()
      | matches ->
          packagekit#status >>= function
          | `Unavailable _ -> Lwt.return ()
          | `Ok ->
              let package_names = matches |> List.map (fun (elem, _props) -> Element.package elem) in
              let hint = Feed_url.format_url (Feed.url feed) in
              packagekit#check_for_candidates ~ui ~hint package_names

    method! install_distro_packages ui typ items =
      match typ with
      | "packagekit" ->
          let packagekit = Lazy.force packagekit in
          begin packagekit#install_packages ui items >>= function
          | `Cancel -> Lwt.return `Cancel
          | `Ok ->
              items |> List.iter (fun (impl, _rm) ->
                self#fixup_main impl
              );
              Lwt.return `Ok end
      | _ ->
          let names = items |> List.map (fun (_impl, rm) -> snd rm.Impl.distro_install_info) in
          ui#confirm (Printf.sprintf
            "This program depends on some packages that are available through your distribution. \
             Please install them manually using %s before continuing. Or, install 'packagekit' and I can \
             use that to install things. The packages are:\n\n- %s" typ (String.concat "\n- " names))
  end

let generic_distribution ~packagekit config =
  object
    inherit packagekit_distro ~packagekit config
    val check_host_python = true
    val distro_name = "fallback"
    val id_prefix = "package:fallback"
  end

let try_cleanup_distro_version_warn version package_name =
  match Version.try_cleanup_distro_version version with
  | None -> log_warning "Can't parse distribution version '%s' for package '%s'" version package_name; None
  | Some zi_version -> Some zi_version

let iter_dir system fn path =
  match system#readdir path with
  | Error ex when U.is_dir system path -> raise ex
  | Error ex -> log_debug ~ex "Failed to read directory '%s'" path
  | Ok items -> items |> Array.iter fn

(** Lookup [elem]'s package in the cache. Generate the ID(s) for the cached implementations and check that one of them
    matches the [id] attribute on [elem].
    Returns [false] if the cache is out-of-date. *)
let check_cache id_prefix elem cache =
  let package = Element.package elem in
  let sel_id = Element.id elem in
  let matches (installed_version, machine) =
    let installed_id = Format.asprintf "%s:%s:%a:%s" id_prefix package Version.pp installed_version (Arch.format_machine_or_star machine) in
    (* log_warning "Want %s %s, have %s" package sel_id installed_id; *)
    sel_id = installed_id in
  List.exists matches (fst (Distro_cache.get cache package))

module Debian = struct
  module Apt_cache : sig
    type t
    (** An in-memory cache of results from apt-cache. *)

    type entry = {
      version : Version.t;
      machine : Arch.machine option;
      size : Int64.t option;
    }

    val make : unit -> t
    (** [make ()] is a fresh empty cache. *)

    val update : t -> system -> string list -> [`Ok | `Cancelled] Lwt.t
    (** [update t system packages] runs apt-cache on each package and stores the results in [t]. *)

    val cached_result : t -> string -> [`Available of entry | `Unavailable | `Not_checked]
    (** [cached_result t package] is the currently stored result for [package], if any.
        Returns [`Unavailable] if "apt-cache" didn't know about the package, or [`Not_checked] if
        we haven't asked yet. *)

    val is_available : t -> string -> bool
    (** [is_available t package] is [true] iff the package is known to be available. *)
  end = struct
    type entry = {
      version : Version.t;
      machine : Arch.machine option;
      size : Int64.t option;
    }

    type t = (string, [`Available of entry | `Unavailable] Lwt.t) Hashtbl.t

    let make () = Hashtbl.create 10

    let parse_cache_line line =
      match XString.(split_pair re_space) (String.trim line) with
      | None -> `Unknown
      | Some (k, v) ->
        let v = String.trim v in
        match k with
        | "Version:" -> `Version v
        | "Architecture:" -> `Architecture v
        | "Size:" -> `Size (Int64.of_string v)
        | _ -> `Unknown

    (* Avoid running too many apt-cache processes at the same time. *)
    let mux = Lwt_mutex.create ()

    let run system package =
      Lwt.catch
        (fun () ->
           let stderr = if Support.Logging.will_log Support.Logging.Debug then None else Some `Dev_null in
           Lwt_mutex.with_lock mux (fun () ->
               Lwt_process.pread ?stderr (U.make_command system ["apt-cache"; "--no-all-versions"; "show"; "--"; package])
             ) >>= fun out ->
           let machine = ref None in
           let version = ref None in
           let size = ref None in
           let stream = U.stream_of_lines out in
           begin try
               while true do
                 match parse_cache_line (Stream.next stream) with
                 | `Version x -> version := try_cleanup_distro_version_warn x package
                 | `Architecture x -> machine := Some (Support.System.canonical_machine x)
                 | `Size x -> size := Some x
                 | `Unknown -> ()
               done
             with Stream.Failure -> ()
           end;
           match !version, !machine with
           | Some version, Some machine ->
             let machine = Arch.parse_machine machine in
             Lwt.return (`Available {version; machine; size = !size})
           | _ -> Lwt.return `Unavailable
        )
        (function
          | Lwt.Canceled as ex -> Lwt.fail ex
          | ex ->
            log_warning ~ex "'apt-cache show %s' failed" package;
            Lwt.return `Unavailable
        )

    let update t system package_names =
      Lwt.catch
        (fun () ->
           package_names |> Lwt_list.iter_s (fun package ->
               (* (multi-arch support? can there be multiple candidates?) *)
               match Hashtbl.find_opt t package with
               | Some result when Lwt.state result = Lwt.Sleep -> result >|= ignore  (* Already checking *)
               | _ ->
                 let result = run system package in
                 Hashtbl.replace t package result;
                 result >|= ignore
             )
           >|= fun () -> `Ok
        )
        (function
          | Lwt.Canceled -> Lwt.return `Cancelled
          | ex -> Lwt.fail ex
        )

    let cached_result t package_name =
      match Hashtbl.find_opt t package_name with
      | None -> `Not_checked
      | Some x ->
        match Lwt.state x with
        | Lwt.Return x -> (x :> [`Available of entry | `Unavailable | `Not_checked])
        | Lwt.Sleep | Lwt.Fail _ -> `Not_checked

    let is_available t package_name =
      match cached_result t package_name with
      | `Available _ -> true
      | `Unavailable | `Not_checked -> false
  end

  module Dpkg : sig
    val db_status : filepath
    (** The location of the status file. *)

    val query : #processes -> string -> (Version.t * Arch.machine option) list
    (** [query system package_name] returns information about installed packages named [package_name]. *)
  end = struct
    let db_status = "/var/lib/dpkg/status"

    (* It's OK if dpkg-query returns a non-zero exit status. *)
    let error_ok child_pid =
      match snd (Support.System.waitpid_non_intr child_pid) with
      | Unix.WEXITED _ -> ()
      | status -> Support.System.check_exit_status status

    let with_dev_null fn =
      U.finally_do Unix.close (Unix.openfile Support.System.dev_null [Unix.O_WRONLY] 0) fn

    (* Returns information about this package, or [] if it's not installed. *)
    let query system package_name =
      let results = ref [] in
      with_dev_null @@ fun dev_null ->
      ["dpkg-query"; "-W"; "--showformat=${Version}\t${Architecture}\t${Status}\n"; "--"; package_name]
      |> U.check_output ~reaper:error_ok ~stderr:(`FD dev_null) system (fun ch  ->
          try
            while true do
              let line = input_line ch in
              match Str.bounded_split_delim XString.re_tab line 3 with
              | [] -> ()
              | [version; debarch; status] ->
                if XString.ends_with status " installed" then (
                  let debarch =
                    try XString.tail debarch (String.rindex debarch '-' + 1)
                    with Not_found -> debarch in
                  match try_cleanup_distro_version_warn version package_name with
                  | None -> ()
                  | Some clean_version ->
                    let r = (clean_version, (Arch.parse_machine (Support.System.canonical_machine (String.trim debarch)))) in
                    results := r :: !results
                )
              | _ -> log_warning "Can't parse dpkg output: '%s'" line
            done
          with End_of_file -> ()
        );
      !results
  end

  let debian_distribution ?(status_file=Dpkg.db_status) ~packagekit config =
    let apt_cache = Apt_cache.make () in
    let system = config.system in

    let fixup_java_main impl java_version =
      let java_arch =
        match Arch.format_machine_or_star impl.Impl.machine with
        | "x86_64" -> Some "amd64"
        | "*" -> log_warning "BUG: Missing machine type on Java!"; None
        | m -> Some m in

      java_arch |> pipe_some (fun java_arch ->
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
        )
      ) in

    object (self : #Distro.distribution)
      inherit packagekit_distro ~packagekit config as super
      val check_host_python = false

      val distro_name = "Debian"
      val id_prefix = "package:deb"
      val cache = Distro_cache.create_lazy config ~cache_leaf:"dpkg-status2.cache" ~source:status_file ~if_missing:(Dpkg.query system)

      (* If we added apt_cache results AND package kit is unavailable, this is set
       * so that we include them in the results. Otherwise, we just take the PackageKit results. *)
      val mutable use_apt_cache_results = false

      method! private is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem

      method! private get_package_impls query =
        let packagekit = Lazy.force packagekit in
        let package_name = Query.package query in
        (* Add any PackageKit candidates *)
        begin match Lwt.state packagekit#status with
        | Lwt.Return `Ok | Lwt.Fail _ -> super#get_package_impls query;
        | Lwt.Sleep -> ()   (* Only use apt-cache once we know PackageKit is missing *)
        | Lwt.Return (`Unavailable _) ->
            (* Add apt-cache candidates if we're not using PackageKit *)
            match Apt_cache.cached_result apt_cache package_name with
            | `Not_checked -> ()
            | `Available {Apt_cache.version; machine; size = _} ->
                let package_state = `Uninstalled {Impl.distro_size = None;
                                                  distro_install_info = ("apt-get install", package_name)} in
                self#add_package_implementation ~package_state ~version ~machine ~quick_test:None ~distro_name query
            | `Unavailable ->
                Query.problem query "%s: not known to apt-cache" package_name
        end;
        (* Add installed packages by querying dpkg. *)
        let infos, quick_test = Distro_cache.get cache package_name in
        infos |> List.iter (fun (version, machine) ->
          self#add_package_implementation ~package_state:`Installed ~version ~machine ~quick_test ~distro_name query
        )

      method! check_for_candidates ~ui feed =
        match Distro.get_matching_package_impls self feed with
        | [] -> Lwt.return ()
        | matches ->
            let hint = Feed_url.format_url (Feed.url feed) in
            let packagekit = Lazy.force packagekit in
            let package_names = matches |> List.map (fun (elem, _props) -> Element.package elem) in
            (* Check apt-cache to see whether we have the pacakges. If PackageKit isn't available, we'll use these
             * results directly. If it is available, we'll use these results to filter the PackageKit query, because
             * it doesn't like queries for missing packages (it tends to abort the query early and miss some results). *)
            let apt =
              with_simple_progress (fun progress ->
                  let apt = Apt_cache.update apt_cache system package_names in
                  let cancel () = Lwt.cancel apt; Lwt.return () in
                  ui#monitor {Downloader.cancel; url = "apt-cache"; progress; hint = Some hint};
                  apt
                )
            in
            packagekit#status >>= fun pkgkit_status ->
            apt >>= function
            | `Cancelled -> Lwt.return ()
            | `Ok ->
              match pkgkit_status with
              | `Ok ->
                package_names
                |> List.filter (Apt_cache.is_available apt_cache)
                |> packagekit#check_for_candidates ~ui ~hint
              | `Unavailable _ ->
                (* No PackageKit. Use apt-cache directly. *)
                use_apt_cache_results <- true;
                Lwt.return ()

      method! private add_package_implementation ?id ?main query ~version ~machine ~quick_test ~package_state ~distro_name =
        let package_name = Query.package query in
        let version =
          match package_name, version with
          | ("openjdk-6-jre" | "openjdk-7-jre"), (([major], Version.Pre) :: (minor, mmod) :: rest) ->
            (* Debian marks all Java versions as pre-releases
               See: http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=685276 *)
            (major :: minor, mmod) :: rest
          | _ -> version in

        super#add_package_implementation ?id ?main query ~version ~machine ~quick_test ~package_state ~distro_name

      method! private get_correct_main impl run_command =
        let id = Impl.get_attr_ex Constants.FeedAttr.id impl in
        if XString.starts_with id "package:deb:openjdk-6-jre:" then
          fixup_java_main impl "6-openjdk"
        else if XString.starts_with id "package:deb:openjdk-7-jre:" then
          fixup_java_main impl "7-openjdk"
        else
          super#get_correct_main impl run_command
    end
end

module RPM = struct
  let rpm_db_packages = "/var/lib/rpm/Packages"

  let rpm_distribution ?(rpm_db_packages = rpm_db_packages) ~packagekit config =
    let fixup_java_main impl java_version =
      (* (note: on Fedora, unlike Debian, the arch is x86_64, not amd64) *)

      match impl.Impl.machine with
      | None -> log_warning "BUG: Missing machine type on Java!"; None
      | Some java_arch ->
          let java_bin = Printf.sprintf "/usr/lib/jvm/jre-%s.%s/bin/java" java_version (Arch.format_machine java_arch) in
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

    let regenerate add_entry =
      ["rpm"; "-qa"; "--qf=%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n"]
      |> U.check_output config.system (fun from_rpm  ->
        try
          while true do
            let line = input_line from_rpm in
            match Str.bounded_split_delim XString.re_tab line 3 with
            | ["gpg-pubkey"; _; _] -> ()
            | [package; version; rpmarch] ->
                let zi_arch = Support.System.canonical_machine (String.trim rpmarch) |> Arch.parse_machine in
                try_cleanup_distro_version_warn version package |> if_some (fun clean_version ->
                  add_entry package (clean_version, zi_arch)
                )
            | _ -> log_warning "Invalid output from 'rpm': %s" line
          done
        with End_of_file -> ()
      ) in

    object (self)
      inherit packagekit_distro ~packagekit config as super
      val check_host_python = false

      val distro_name = "RPM"
      val id_prefix = "package:rpm"
      val cache = Distro_cache.create_eager config ~cache_leaf:"rpm-status3.cache" ~source:rpm_db_packages ~regenerate

      method! private get_package_impls query =
        (* Add any PackageKit candidates *)
        super#get_package_impls query;

        (* Add installed packages by querying rpm *)
        let package_name = Query.package query in
        let infos, quick_test = Distro_cache.get cache package_name in
        infos |> List.iter (fun (version, machine) ->
          self#add_package_implementation ~package_state:`Installed ~version ~machine ~quick_test ~distro_name query
        )

      method! private is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem

      method! private get_correct_main impl run_command =
        (* OpenSUSE uses _, Fedora uses . *)
        let id = Impl.get_attr_ex Constants.FeedAttr.id impl in
        let starts x = XString.starts_with id x in
        if starts "package:rpm:java-1.6.0-openjdk:" || starts "package:rpm:java-1_6_0-openjdk:" then
          fixup_java_main impl "1.6.0-openjdk"
        else if starts "package:rpm:java-1.7.0-openjdk:" || starts "package:rpm:java-1_7_0-openjdk:" then
          fixup_java_main impl "1.7.0-openjdk"
        else
          super#get_correct_main impl run_command

      method! private add_package_implementation ?id ?main query ~version ~machine ~quick_test ~package_state ~distro_name =
        let version =
          (* OpenSUSE uses _, Fedora uses . *)
          let package_name = Query.package query |> String.map (function '_' -> '.' | x -> x) in
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

  let arch_distribution ?(arch_db=arch_db) ~packagekit config =
    let packages_dir = arch_db ^ "/local" in
    let parse_dirname entry =
      try
        let build_dash = String.rindex entry '-' in
        let version_dash = String.rindex_from entry (build_dash - 1) '-' in
        Some (String.sub entry 0 version_dash,
              XString.tail entry (version_dash + 1))
      with Not_found -> None in

    let get_arch desc_path =
      let arch = ref None in
      desc_path |> config.system#with_open_in [Open_rdonly; Open_text] (fun ch ->
        try
          while !arch = None do
            let line = input_line ch in
            if line = "%ARCH%" then
              arch := Some (String.trim (input_line ch))
          done
        with End_of_file -> ()
      );
      !arch in

    let entries = ref (-1.0, XString.Map.empty) in
    let get_entries () =
      let (last_read, items) = !entries in
      match config.system#stat packages_dir with
      | Some info when info.Unix.st_mtime > last_read -> (
          match config.system#readdir packages_dir with
          | Ok items ->
              let add map entry =
                match parse_dirname entry with
                | Some (name, version) -> XString.Map.add name version map
                | None -> map in
              let new_items = Array.fold_left add XString.Map.empty items in
              entries := (info.Unix.st_mtime, new_items);
              new_items
          | Error ex ->
              log_warning ~ex "Can't read packages dir '%s'!" packages_dir;
              items
      )
      | _ -> items in

    object (self : #Distro.distribution)
      inherit packagekit_distro ~packagekit config as super
      val check_host_python = false

      val distro_name = "Arch"
      val id_prefix = "package:arch"

      method! private get_package_impls query =
        (* Start with impls from PackageKit *)
        super#get_package_impls query;

        (* Check the local package database *)
        let package_name = Query.package query in
        log_debug "Looking up distribution packages for %s" package_name;
        let items = get_entries () in
        match XString.Map.find_opt package_name items with
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
                    let machine = Arch.parse_machine machine in
                    let quick_test = Some (desc_path, Exists) in
                    self#add_package_implementation ~package_state:`Installed ~version ~machine ~quick_test ~distro_name query
    end
end

module Mac = struct
  let macports_db = "/opt/local/var/macports/registry/registry.db"

  let darwin_distribution config =
    let get_version main =
      let first_line = [main; "--version"] |> U.check_output config.system input_line in
      try
        let i = String.rindex first_line ' ' in
        XString.tail first_line (i + 1)
      with Not_found -> first_line in

    let java_home version arch =
      U.finally_do Unix.close (Unix.openfile Support.System.dev_null [Unix.O_WRONLY] 0)
        (fun dev_null ->
          let reaper pid = Support.System.waitpid_non_intr pid |> ignore in
          ["/usr/libexec/java_home"; "--failfast"; "--version"; version; "--arch"; arch]
          |> U.check_output config.system ~reaper ~stderr:(`FD dev_null) (fun ch -> try input_line ch with End_of_file -> "")
          |> String.trim
        ) in

    object (self : #distribution)
      inherit Distro.distribution config
      val distro_name = "Darwin"
      val id_prefix = "package:darwin"
      val check_host_python = true

      method get_package_impls query =
        let package_name = Query.package query in
        match package_name with
        | "openjdk-6-jre" | "openjdk-6-jdk" -> self#find_java "1.6" "6" query
        | "openjdk-7-jre" | "openjdk-7-jdk" -> self#find_java "1.7" "7" query
        | "openjdk-8-jre" | "openjdk-8-jdk" -> self#find_java "1.8" "8" query
        | "gnupg" -> self#find_program "/usr/local/bin/gpg" query
        | "gnupg2" -> self#find_program "/usr/local/bin/gpg2" query
        | "make" -> self#find_program "/usr/bin/make" query
        | package_name ->
            if XString.Map.is_empty (Query.results query) then
              Query.problem query "%s: Unknown Darwin/OS X package" package_name
            (* else we have MacPorts results *)

      method private find_program main query =
        config.system#stat main |> if_some (fun info ->
          let x_ok = try Unix.access main [Unix.X_OK]; true with Unix.Unix_error _ -> false in
          if x_ok then (
            let (_host_os, host_machine) = Arch.platform config.system in
            let package_name = Query.package query in
            try_cleanup_distro_version_warn (get_version main) package_name |> if_some (fun version ->
              self#add_package_implementation
                ~main
                ~package_state:`Installed
                ~version
                ~machine:(Some host_machine)
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
                ~package_state:`Installed
                ~version:(Version.parse zero_version)
                ~machine:(Arch.parse_machine machine)
                ~quick_test:(Some (main, UnchangedSince info.Unix.st_mtime))
                ~distro_name
                query
          | None -> ()
        )

      method check_for_candidates ~ui:_ _feed = Lwt.return ()
    end

  let macports_distribution ?(macports_db=macports_db) config =
    let re_version = Str.regexp "^@*\\([^+]+\\)\\(\\+.*\\)?$" in (* strip variants *)
    let re_extra = Str.regexp " platform='\\([^' ]*\\)\\( [0-9]+\\)?' archs='\\([^']*\\)'" in

    let regenerate add_entry =
      ["port"; "-v"; "installed"] |> U.check_output config.system (fun ch ->
        try
          while true do
            let line = input_line ch in
            log_debug "Got: '%s'" line;
            if XString.starts_with line " " then (
              let line = String.trim line in
              match Str.bounded_split_delim XString.re_space line 3 with
              | [package; version; extra] when XString.starts_with extra "(active)" ->
                  log_debug "Found package='%s' version='%s' extra='%s'" package version extra;
                  if Str.string_match re_version version 0 then (
                    let version = Str.matched_group 1 version in
                    try_cleanup_distro_version_warn version package |> if_some (fun version ->
                      if Str.string_match re_extra extra 0 then (
                        (* let platform = Str.matched_group 1 extra in *)
                        (* let major = Str.matched_group 2 extra in *)
                        let archs = Str.matched_group 3 extra in
                        Str.split XString.re_space archs |> List.iter (fun arch ->
                          let zi_arch = Support.System.canonical_machine arch in
                          add_entry package (version, Arch.parse_machine zi_arch)
                        )
                      ) else (
                        add_entry package (version, None)
                      )
                    )
                  ) else log_debug "Failed to match version '%s'" version
              | [_package; _version; _extra] -> ()
              | [_package; _version] -> ()
              | _ -> Safe_exn.failf "Invalid port output: '%s'" line
            )
          done
        with End_of_file -> ()
      ) in

    object (self : #distribution)
      inherit Distro.distribution config as super

      val! system_paths = ["/opt/local/bin"]
      val darwin = darwin_distribution config
      val check_host_python = false     (* Darwin will do it *)

      val distro_name = "MacPorts"
      val id_prefix = "package:macports"
      val cache = Distro_cache.create_eager config ~cache_leaf:"macports-status2.cache" ~source:macports_db ~regenerate

      method! private is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem

      method! match_name name = super#match_name name || darwin#match_name name

      method private get_package_impls query =
        let package_name = Query.package query in
        let infos, quick_test = Distro_cache.get cache package_name in
        infos |> List.iter (fun (version, machine) ->
          self#add_package_implementation ~package_state:`Installed ~version ~machine ~quick_test ~distro_name query
        );
        darwin#get_package_impls query

      method check_for_candidates ~ui:_ _feed = Lwt.return ()
    end

  let darwin_distribution config = (darwin_distribution config :> Distro.distribution)
end

module Win = struct
  let windows_distribution config =
    let api = config.system#windows_api |? lazy (Safe_exn.failf "Failed to load Windows support module!") in

    let read_hklm_reg reader =
      (reader ~key64:false, reader ~key64:true)
    in
    object (self)
      inherit Distro.distribution config
      val check_host_python = false (* (0install's bundled Python may not be generally usable) *)

      val! system_paths = []

      val distro_name = "Windows"
      val id_prefix = "package:windows"

      method private get_package_impls query =
        match Query.package query with
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
        | package_name ->
            Query.problem query "%s: Unknown Windows package" package_name

      method check_for_candidates ~ui:_ _feed = Lwt.return ()

      method private find_netfx win_version zero_version query =
        let reg_path = "SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\" ^ win_version in
        let netfx32_install, netfx64_install = read_hklm_reg (api#read_registry_int reg_path "Install") in

        [(netfx32_install, "i486"); (netfx64_install, "x86_64")] |> List.iter (function
          | None, _ -> ()
          | Some install, machine ->
              let version = Version.parse zero_version in
              let package_state =
                if install = 1 then `Installed
                else `Uninstalled Impl.({distro_size = None; distro_install_info = ("Windows installer", "NetFX")}) in
              self#add_package_implementation
                ~main:""      (* .NET executables do not need a runner on Windows but they need one elsewhere *)
                ~package_state
                ~version
                ~machine:(Arch.parse_machine machine)
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
              let version = Version.parse zero_version in
              let package_state =
                if install = 1 && release >= release_version then `Installed
                else `Uninstalled Impl.({distro_size = None; distro_install_info = ("Windows installer", "NetFX")}) in
              self#add_package_implementation
                ~main:""      (* .NET executables do not need a runner on Windows but they need one elsewhere *)
                ~package_state
                ~version
                ~machine:(Arch.parse_machine machine)
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
                  let version = Version.parse zero_version in
                  let quick_test = Some (java_bin, UnchangedSince info.Unix.st_mtime) in
                  self#add_package_implementation
                    ~main:java_bin
                    ~package_state:`Installed
                    ~version
                    ~machine:(Arch.parse_machine machine)
                    ~quick_test
                    ~distro_name
                    query
        )
    end

  let cygwin_log = "/var/log/setup.log"

  (* Note: this is ported from the Python but completely untested. *)
  let cygwin_distribution config =
    let re_whitespace = Str.regexp "[ \t]+" in
    let regenerate add_entry =
      ["cygcheck"; "-c"; "-d"] |> U.check_output config.system (fun from_cyg  ->
        try
          while true do
            match input_line from_cyg with
            | "Cygwin Package Information" | "" -> ()
            | line ->
                match XString.split_pair_safe re_whitespace line with
                | ("Package", "Version") -> ()
                | (package, version) ->
                    try_cleanup_distro_version_warn version package |> if_some (fun clean_version ->
                      add_entry package (clean_version, None)
                    )
          done
        with End_of_file -> ()
      ) in
    object (self)
      inherit Distro.distribution config as super
      val distro_name = "Cygwin"
      val id_prefix = "package:cygwin"
      val check_host_python = false

      val cache = Distro_cache.create_eager config ~cache_leaf:"cygcheck-status2.cache" ~source:cygwin_log ~regenerate

      method! private is_installed elem =
        check_cache id_prefix elem cache || super#is_installed elem

      method private get_package_impls query =
        let package_name = Query.package query in
        match Distro_cache.get cache package_name with
        | [], _ -> Query.problem query "%s: Unknown Cygwin package" package_name
        | infos, quick_test ->
        infos |> List.iter (fun (version, machine) ->
          self#add_package_implementation ~package_state:`Installed ~version ~machine ~quick_test ~distro_name query
        )

      method check_for_candidates ~ui:_ _feed = Lwt.return ()
    end
end

module Ports = struct
  let pkg_db = "/var/db/pkg"

  let ports_distribution ?(pkg_db=pkg_db) ~packagekit config =
    let re_name_version = Str.regexp "^\\(.+\\)-\\([^-]+\\)$" in

    object (self)
      inherit packagekit_distro ~packagekit config  (* Can ports use PackageKit? Not sure. *)
      val id_prefix = "package:ports"
      val distro_name = "Ports"
      val check_host_python = true

      method! private get_package_impls query =
        let package_name = Query.package query in
        pkg_db |> iter_dir config.system (fun pkgname ->
          let pkgdir = pkg_db +/ pkgname in
          if U.is_dir config.system pkgdir then (
            if Str.string_match re_name_version pkgname 0 then (
              let name = Str.matched_group 1 pkgname in
              let version = Str.matched_group 2 pkgname in
              if name = package_name then (
                try_cleanup_distro_version_warn version package_name |> if_some (fun version ->
                  let (_host_os, host_machine) = Arch.platform config.system in
                  self#add_package_implementation
                    ~package_state:`Installed
                    ~version
                    ~machine:(Some host_machine)
                    ~quick_test:None
                    ~distro_name
                    query
                )
              )
            ) else (
              Query.problem query "Cannot parse version from Ports package named '%s'" pkgname
            )
          )
        )
    end
end

module Gentoo = struct
  let is_digit = function
    | '0' .. '9' -> true
    | _ -> false

  let gentoo_distribution ?(pkgdir=Ports.pkg_db) ~packagekit config =
    object (self)
      inherit packagekit_distro ~packagekit config as super
      val! valid_package_name = Str.regexp "^[^.-][^/]*/[^./][^/]*$"
      val distro_name = "Gentoo"
      val id_prefix = "package:gentoo"
      val check_host_python = false

      method! private get_package_impls query =
        (* Add any PackageKit candidates *)
        super#get_package_impls query;

        let re_version_start = Str.regexp "-[0-9]" in

        let package_name = Query.package query in
        match Str.bounded_split_delim XString.re_slash package_name 2 with
        | [category; leafname] ->
            let category_dir = pkgdir +/ category in
            let match_prefix = leafname ^ "-" in

            category_dir |> iter_dir config.system (fun filename ->
              if XString.starts_with filename match_prefix && is_digit (filename.[String.length match_prefix]) then (
                let pf_path = category_dir +/ filename +/ "PF"in
                let pf_mtime = (config.system#lstat pf_path |? lazy (Safe_exn.failf "Missing '%s' file!" pf_path)).Unix.st_mtime in
                let name = pf_path|> config.system#with_open_in [Open_rdonly] input_line |> String.trim in

                match (try Some (Str.search_forward re_version_start name 0) with Not_found -> None) with
                | None -> log_warning "Cannot parse version from Gentoo package named '%s'" name
                | Some i ->
                  try_cleanup_distro_version_warn (XString.tail name (i + 1)) package_name |> if_some (fun version ->
                    let machine =
                      if category = "app-emulation" && XString.starts_with name "emul-" then (
                        match Str.bounded_split_delim XString.re_dash name 4 with
                        | [_; _; machine; _] -> machine
                        | _ -> "*"
                      ) else (
                        category_dir +/ filename +/ "CHOST" |> config.system#with_open_in [Open_rdonly] (fun ch ->
                          input_line ch |> XString.(split_pair_safe re_dash) |> fst
                        )
                      ) in
                    let machine = Arch.parse_machine (Support.System.canonical_machine machine) in
                    self#add_package_implementation
                      ~package_state:`Installed
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

  let slack_distribution ?(packages_dir=slack_db) ~packagekit config =
    object (self)
      inherit packagekit_distro ~packagekit config as super
      val distro_name = "Slack"
      val id_prefix = "package:slack"
      val check_host_python = false

      method! private get_package_impls query =
        (* Add any PackageKit candidates *)
        let package_name = Query.package query in
        super#get_package_impls query;
        packages_dir |> iter_dir config.system (fun entry ->
          match Str.bounded_split_delim XString.re_dash entry 4 with
          | [name; version; arch; build] when name = package_name ->
              let machine = Arch.parse_machine (Support.System.canonical_machine arch) in
              try_cleanup_distro_version_warn (version ^ "-" ^ build) package_name |> if_some (fun version ->
              self#add_package_implementation
                ~package_state:`Installed
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

let get_host_distribution ~packagekit config =
  Distro.of_provider @@
  let exists = config.system#file_exists in
  match Sys.os_type with
  | "Unix" ->
      let is_debian =
        match config.system#stat Debian.Dpkg.db_status with
        | Some info when info.Unix.st_size > 0 -> true
        | _ -> false in

      if is_debian then
        Debian.debian_distribution ~packagekit config
      else if exists ArchLinux.arch_db then
        ArchLinux.arch_distribution ~packagekit config
      else if exists RPM.rpm_db_packages then
        RPM.rpm_distribution ~packagekit config
      else if exists Mac.macports_db then
        Mac.macports_distribution config
      else if exists Ports.pkg_db then (
        if config.system#platform.Platform.os = "Linux" then
          Gentoo.gentoo_distribution ~packagekit config
        else
          Ports.ports_distribution ~packagekit config
      ) else if exists Slackware.slack_db then
        Slackware.slack_distribution ~packagekit config
      else begin match config.system#platform.Platform.os with
      | "Darwin" | "MacOSX" ->
          Mac.darwin_distribution config
      | _unknown ->
          generic_distribution ~packagekit config
      end
  | "Win32" -> Win.windows_distribution config
  | "Cygwin" -> Win.cygwin_distribution config
  | _ ->
      generic_distribution ~packagekit config
