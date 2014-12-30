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

(** Return the <package-implementation> elements that best match this distribution.
 * Filters out those which fail [distribution#is_valid_package_name]. *)
let get_matching_package_impls distro feed =
  let best_score = ref 0 in
  let best_impls = ref [] in
  feed.Feed.package_implementations |> List.iter (function (elem, _) as package_impl ->
    let package_name = Element.package elem in
    if distro#is_valid_package_name package_name then (
        let distributions = default "" @@ Element.distributions elem in
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
    )
  );
  !best_impls

type query = {
  elem : [`package_impl] Element.t; (* The <package-element> which generated this query *)
  package_name : string;            (* The 'package' attribute on the <package-element> *)
  elem_props : Impl.properties;     (* Properties on or inherited by the <package-element> - used by [add_package_implementation] *)
  feed : Feed.feed;                 (* The feed containing the <package-element> *)
  results : Impl.distro_implementation Support.Common.StringMap.t ref;
}

let make_query feed elem elem_props results = {
  elem;
  package_name = Element.package elem;
  elem_props;
  feed;
  results;
}

type quick_test_condition = Exists | UnchangedSince of float
type quick_test = (Support.Common.filepath * quick_test_condition)

let python_test_code =
  "import sys\n" ^
  "python_version = '.'.join([str(v) for v in sys.version_info if isinstance(v, int)])\n" ^
  "p_info = (sys.executable or '/usr/bin/python', python_version)\n" ^
  "try:\n" ^
  "  if sys.version_info[0] > 2:\n" ^
  "    from gi.repository import GObject as gobject\n" ^
  "  else:\n" ^
  "    import gobject\n" ^
  "  if gobject.__file__.startswith('<'):\n" ^
  "    path = gobject.__path__    # Python 3\n" ^
  "    if type(path) is bytes:\n" ^
  "        path = path.decode(sys.getfilesystemencoding())\n" ^
  "  else:\n" ^
  "    path = gobject.__file__    # Python 2\n" ^
  "  version = '.'.join(str(x) for x in gobject.pygobject_version)\n" ^
  "  g_info = (path, version)\n" ^
  "except BaseException:\n" ^
  "  g_info = None\n" ^
  "import json\n" ^
  "print(json.dumps([p_info, g_info]))\n"

(** Set quick-test-file and quick-test-mtime from path. *)
let get_quick_test_attrs path =
  let mtime = (Unix.stat path).Unix.st_mtime in
  Q.AttrMap.empty
  |> Q.AttrMap.add_no_ns FeedAttr.quick_test_file path
  |> Q.AttrMap.add_no_ns FeedAttr.quick_test_mtime (Printf.sprintf "%.0f" mtime)

let make_restricts_distro iface_uri distros = { Impl.
    dep_qdom = Element.dummy_restricts;
    dep_importance = `restricts;
    dep_iface = iface_uri;
    dep_src = false;
    dep_restrictions = [Impl.make_distribtion_restriction distros];
    dep_required_commands = [];
    dep_if_os = None;
    dep_use = None;
  }

class virtual distribution config =
  let system = config.system in

  let python_info = lazy (
    ["python"; "python2"; "python3"] |> U.filter_map (fun name ->
      U.find_in_path system name |> pipe_some (fun path ->
        try
          let json = [path; "-c"; python_test_code] |> U.check_output system Yojson.Basic.from_channel in
          match json with
          | `List [`List [`String python_path; `String python_version]; gobject_json] ->
              let gobject =
                match gobject_json with
                | `Null -> None
                | `List [`String gobject_path; `String gobject_version] -> Some (gobject_path, gobject_version)
                | _ -> raise_safe "Bad JSON: '%s'" (Yojson.Basic.to_string json) in
              Some ((python_path, python_version), gobject)
          | _ -> raise_safe "Bad JSON: '%s'" (Yojson.Basic.to_string json)
        with ex -> log_warning ~ex "Failed to get details from Python"; None
      )
    )
  ) in

  let make_host_impl path version ~package ?(commands=StringMap.empty) ?(requires=[]) from_feed id =
    let (_host_os, host_machine) = Arch.platform system in
    let props = { Impl.
      attrs = get_quick_test_attrs path
        |> Q.AttrMap.add_no_ns FeedAttr.from_feed (Feed_url.format_url (`distribution_feed from_feed))
        |> Q.AttrMap.add_no_ns FeedAttr.id id
        |> Q.AttrMap.add_no_ns FeedAttr.stability "packaged"
        |> Q.AttrMap.add_no_ns FeedAttr.version version
        |> Q.AttrMap.add_no_ns FeedAttr.package package;
      requires;
      bindings = [];
      commands;
    } in { Impl.
      qdom = ZI.make "host-package-implementation";
      props;
      stability = Packaged;
      os = None;
      machine = Some host_machine;       (* (hopefully) *)
      parsed_version = Version.parse version;
      impl_type = `package_impl { Impl.
        package_distro = "host";
        package_state = `installed;
      }
    } in

  let get_host_impls = function
    | `remote_feed "http://repo.roscidus.com/python/python" as url ->
        (* We support Python on platforms with unsupported package managers
           by running it manually and parsing the output. Ideally we would
           cache this information on disk. *)
        Lazy.force python_info |> List.map (fun ((path, version), _) ->
          let id = "package:host:python:" ^ version in
          let run = ZI.make "command"
            ~attrs:(
              Q.AttrMap.singleton "name" "run"
              |> Q.AttrMap.add_no_ns "path" path
            ) in
          let commands = StringMap.singleton "run" Impl.({command_qdom = run; command_requires = []; command_bindings = []}) in
          (id, make_host_impl ~package:"host-python" path version ~commands url id)
        )
    | `remote_feed "http://repo.roscidus.com/python/python-gobject" as url ->
        Lazy.force python_info |> U.filter_map (function
          | (_, Some (path, version)) ->
              let id = "package:host:python-gobject:" ^ version in
              let requires = [make_restricts_distro "http://repo.roscidus.com/python/python" "host"] in
              Some (id, make_host_impl ~package:"host-python-gobject" path version ~requires url id)
          | (_, None) -> None
        )
    | _ -> [] in

  let fixup_main distro_get_correct_main impl =
    let open Impl in
    match get_command_opt "run" impl with
    | None -> ()
    | Some run ->
        match distro_get_correct_main impl run with
        | None -> ()
        | Some new_main ->
            run.command_qdom <- {run.command_qdom with
              Q.attrs = run.command_qdom.Q.attrs |> Q.AttrMap.add_no_ns "path" new_main
            } in

  object (self)
    val virtual distro_name : string
    val virtual check_host_python : bool
    val system_paths = ["/usr/bin"; "/bin"; "/usr/sbin"; "/sbin"]

    val valid_package_name = Str.regexp "^[^.-][^/]*$"

    val packagekit = !Packagekit.packagekit config

    (** All IDs will start with this string (e.g. "package:deb") *)
    val virtual id_prefix : string

    method is_valid_package_name name =
      if Str.string_match valid_package_name name 0 then true
      else (
        log_info "Ignoring invalid distribution package name '%s'" name;
        false
      )

    (** Can we use packages for this distribution? For example, MacPortsDistribution can use "MacPorts" and "Darwin" packages. *)
    method match_name name = (name = distro_name)

    (** Convenience wrapper for [add_result] that builds a new implementation from the given attributes. *)
    method private add_package_implementation ?id ?main (query:query) ~version ~machine ~quick_test ~package_state ~distro_name =
      let version_str = Version.to_string version in
      let id = id |? lazy (Printf.sprintf "%s:%s:%s:%s" id_prefix query.package_name version_str (Arch.format_machine_or_star machine)) in
      let props = query.elem_props in
      let elem = query.elem in

      let props =
        match main with
        | None -> props
        | Some path ->
            (* We may add or modify the main executable path. *)
            let open Impl in
            let run_command =
              match StringMap.find "run" props.commands with
              | Some command ->
                  {command with command_qdom = 
                    {command.command_qdom with
                      Qdom.attrs = command.command_qdom.Qdom.attrs |> Qdom.AttrMap.add_no_ns "path" path
                    }
                  };
              | None ->
                  make_command "run" path in
            {props with commands = StringMap.add "run" run_command props.commands} in

      let new_attrs = ref props.Impl.attrs in
      let set name value =
        new_attrs := Q.AttrMap.add_no_ns name value !new_attrs in
      set "id" id;
      set "version" version_str;
      set "from-feed" @@ "distribution:" ^ (Q.AttrMap.get_no_ns "from-feed" !new_attrs |? lazy (raise_safe "BUG: Missing feed!"));

      begin match quick_test with
      | None -> ()
      | Some (path, cond) ->
          set FeedAttr.quick_test_file path;
          match cond with
          | Exists -> ()
          | UnchangedSince mtime ->
              set FeedAttr.quick_test_mtime (Int64.of_float mtime |> Int64.to_string) end;

      let open Impl in
      let impl = {
        qdom = Element.as_xml elem;
        os = None;
        machine;
        stability = Packaged;
        props = {props with attrs = !new_attrs};
        parsed_version = version;
        impl_type = `package_impl { package_state; package_distro = distro_name };
      } in

      if package_state = `installed then fixup_main self#get_correct_main impl;

      query.results := StringMap.add id impl !(query.results)

    (** Test whether this <selection> element is still valid. The default implementation tries to load the feed from the
     * feed cache, calls [distribution#get_impls_for_feed] on it and checks whether the required implementation ID is in the
     * returned map. Override this if you can provide a more efficient implementation. *)
    method is_installed elem =
      let master_feed =
        match Element.from_feed elem with
        | None -> Element.interface elem |> Feed_url.parse_non_distro (* (for very old selections documents) *)
        | Some from_feed ->
            match Feed_url.parse from_feed with
            | `distribution_feed master_feed -> master_feed
            | `local_feed _ | `remote_feed _ -> assert false in
      match Feed_cache.get_cached_feed config master_feed with
      | None -> false
      | Some master_feed ->
          let wanted_id = Element.id elem in
          let impls = self#get_impls_for_feed master_feed in
          match StringMap.find wanted_id impls with
          | None -> false
          | Some {Impl.impl_type = `package_impl {Impl.package_state; _}; _} -> package_state = `installed

    (** Get the native implementations (installed or candidates for installation) for this feed.
     * This default implementation finds the best <package-implementation> elements and calls [get_package_impls] on each one. *)
    method get_impls_for_feed ?(init=StringMap.empty) (feed:Feed.feed) : Impl.distro_implementation StringMap.t =
      let results = ref init in

      if check_host_python then (
        get_host_impls feed.Feed.url |> List.iter (fun (id, impl) -> results := StringMap.add id impl !results)
      );

      match get_matching_package_impls self feed with
      | [] -> !results
      | matches ->
          matches |> List.iter (fun (elem, props) ->
            self#get_package_impls (make_query feed elem props results);
          );
          !results

    method private get_package_impls query : unit =
      let package_name = query.package_name in
      packagekit#get_impls package_name |> List.iter (fun info ->
        let {Packagekit.version; Packagekit.machine; Packagekit.installed; Packagekit.retrieval_method} = info in
        let package_state =
          if installed then `installed
          else `uninstalled retrieval_method in
        self#add_package_implementation
          ~version
          ~machine
          ~package_state
          ~quick_test:None
          ~distro_name:distro_name
          query
      )

    (** Called when an installed package is added, or when installation completes. This is useful to fix up the main value.
        The default implementation checks that main exists, and searches [system_paths] for
        it if not. *)
    method private get_correct_main _impl run_command =
      let open Impl in
      ZI.get_attribute_opt "path" run_command.command_qdom |> pipe_some (fun path ->
        if Filename.is_relative path || not (system#file_exists path) then (
          (* Need to search for the binary *)
          let basename = Filename.basename path in
          let basename = if on_windows && not (Filename.check_suffix path ".exe") then basename ^ ".exe" else basename in
          let fixed_path =
            system_paths |> U.first_match (fun d ->
              let path = d +/ basename in
              if system#file_exists path then (
                log_info "Found %s by searching system paths" path;
                Some path
              ) else None
            ) in
          if fixed_path = None then
            log_info "Binary '%s' not found in any system path (checked %s)" basename (String.concat ", " system_paths);
          fixed_path
        ) else None
      )

    (* This default implementation queries PackageKit, if available. *)
    method check_for_candidates : 'a. ui:(#Packagekit.ui as 'a) -> Feed.feed -> unit Lwt.t = fun ~ui feed ->
      match get_matching_package_impls self feed with
      | [] -> Lwt.return ()
      | matches ->
          lwt available = packagekit#is_available in
          if available then (
            let package_names = matches |> List.map (fun (elem, _props) -> Element.package elem) in
            let hint = Feed_url.format_url feed.Feed.url in
            packagekit#check_for_candidates ~ui ~hint package_names
          ) else Lwt.return ()

    method install_distro_packages : 'a. (#Packagekit.ui as 'a) -> string -> _ list -> [ `ok | `cancel ] Lwt.t =
      fun ui typ items ->
        match typ with
        | "packagekit" ->
            begin match_lwt packagekit#install_packages ui items with
            | `cancel -> Lwt.return `cancel
            | `ok ->
                items |> List.iter (fun (impl, _rm) ->
                  fixup_main self#get_correct_main impl
                );
                Lwt.return `ok end
        | _ ->
            let names = items |> List.map (fun (_impl, rm) -> snd rm.Impl.distro_install_info) in
            ui#confirm (Printf.sprintf
              "This program depends on some packages that are available through your distribution. \
               Please install them manually using %s and try again. Or, install 'packagekit' and I can \
               use that to install things. The packages are:\n\n- %s" typ (String.concat "\n- " names))
  end

let is_installed config (distro:distribution) elem =
  match Element.quick_test_file elem with
  | None ->
      let package_name = Element.package elem in
      distro#is_valid_package_name package_name && distro#is_installed elem
  | Some file ->
      match config.system#stat file with
      | None -> false
      | Some info ->
          match Element.quick_test_mtime elem with
          | None -> true      (* quick-test-file exists and we don't care about the time *)
          | Some required_mtime -> (Int64.of_float info.Unix.st_mtime) = required_mtime

let install_distro_packages (distro:distribution) ui impls : [ `ok | `cancel ] Lwt.t =
  let groups = ref StringMap.empty in
  impls |> List.iter (fun impl ->
    let `package_impl {Impl.package_state; _} = impl.Impl.impl_type in
    match package_state with
    | `installed -> raise_safe "BUG: package %s already installed!" (Impl.get_id impl).Feed_url.id
    | `uninstalled rm ->
        let (typ, _info) = rm.Impl.distro_install_info in
        let items = default [] @@ StringMap.find typ !groups in
        groups := StringMap.add typ ((impl, rm) :: items) !groups
  );

  let rec loop = function
    | [] -> Lwt.return `ok
    | (typ, items) :: groups ->
        match_lwt distro#install_distro_packages ui typ items with
        | `ok -> loop groups
        | `cancel -> Lwt.return `cancel in
  !groups |> StringMap.bindings |> loop
