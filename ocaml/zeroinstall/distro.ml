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

(** Return the <package-implementation> elements that best match this distribution. *)
let get_matching_package_impls distro feed =
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

let package_impl_from_packagekit id elem props distro_name info =
  let {Packagekit.version; Packagekit.machine; Packagekit.installed; Packagekit.retrieval_method} = info in
  let open Feed in

  let master_feed = Feed.AttrMap.find ("", "from-feed") props.attrs in
  let set name value attrs = attrs |> Feed.AttrMap.add ("", name) value in

  let attrs = props.attrs
  |> set FeedAttr.id id
  |> set FeedAttr.from_feed @@ "distribution:" ^ master_feed
  |> set FeedAttr.stability "packaged"   (* The GUI likes to know the upstream stability too *)
  |> set FeedAttr.version (Versions.format_version version);
  in

  let props = {props with attrs} in

  let pkg_type = {
    package_installed = installed;
    package_distro = distro_name;
    retrieval_method = Some retrieval_method
  } in
  let pkg = {
    qdom = elem;
    os = None;
    machine;
    stability = Packaged;
    props;
    parsed_version = version;
    impl_type = PackageImpl pkg_type;
  } in
  pkg

class type query =
  object
    method package_name : string
    method elem : Qdom.element
    method props : Feed.properties
    method feed : Feed.feed

    method add_result : string -> Feed.implementation -> unit
    method add_package_implementation :
      id:string ->
      version:string ->
      machine:string ->   (* Use "*" for "any" *)
      extra_attrs:((string * string) list) ->
      is_installed:bool ->
      distro_name:string ->
      unit
  end

let make_query fixup_main feed elem props results =
  object (self : query)
    method package_name = ZI.get_attribute Constants.FeedAttr.package elem
    method elem = elem
    method props = props
    method feed = feed
    method add_result id impl = results := StringMap.add id impl !results

    (** Convenience wrapper for [add_result] that builds a new implementation from the given attributes.
     * If [is_installed] is [true], we also call [fixup_main] on it.
     *)
    method add_package_implementation ~id ~version ~machine ~extra_attrs ~is_installed ~distro_name =
      if is_installed then fixup_main props;
      let new_attrs = ref props.Feed.attrs in
      let set name value =
        new_attrs := Feed.AttrMap.add ("", name) value !new_attrs in
      set "id" id;
      set "version" version;
      set "from-feed" @@ "distribution:" ^ (Feed.AttrMap.find ("", "from-feed") !new_attrs);
      List.iter (fun (n, v) -> set n v) extra_attrs;
      let open Feed in
      let impl = {
        qdom = elem;
        os = None;
        machine = Arch.none_if_star machine;
        stability = Packaged;
        props = {props with attrs = !new_attrs};
        parsed_version = Versions.parse_version version;
        impl_type = PackageImpl { package_installed = is_installed; package_distro = distro_name; retrieval_method = None };
      } in
      self#add_result id impl

  end

class virtual distribution config =
  let system = config.system in
  object (self)
    val virtual distro_name : string
    val system_paths = ["/usr/bin"; "/bin"; "/usr/sbin"; "/sbin"]

    val packagekit = !Packagekit.packagekit config

    (** Can we use packages for this distribution? For example, MacPortsDistribution can use "MacPorts" and "Darwin" packages. *)
    method match_name name = (name = distro_name)

    (** Test whether this <selection> element is still valid. The default implementation tries to load the feed from the
     * feed cache, calls [distribution#get_impls_for_feed] on it and checks whether the required implementation ID is in the
     * returned map. Override this if you can provide a more efficient implementation. *)
    method is_installed elem =
      log_info "No is_installed implementation for '%s'; using slow Python fallback instead!" distro_name;
      let master_feed =
        match ZI.get_attribute_opt FeedAttr.from_feed elem with
        | None -> ZI.get_attribute FeedAttr.interface elem |> Feed_url.parse_non_distro (* (for very old selections documents) *)
        | Some from_feed ->
            match Feed_url.parse from_feed with
            | `distribution_feed master_feed -> master_feed
            | `local_feed _ | `remote_feed _ -> assert false in
      match Feed_cache.get_cached_feed config master_feed with
      | None -> false
      | Some master_feed ->
          let wanted_id = ZI.get_attribute FeedAttr.id elem in
          let impls = self#get_impls_for_feed master_feed in
          match StringMap.find wanted_id impls with
          | None -> false
          | Some impl ->
              match impl.Feed.impl_type with
              | Feed.PackageImpl {Feed.package_installed; _} -> package_installed
              | _ -> assert false

    (** All IDs will start with this string (e.g. "package:deb") *)
    val virtual id_prefix : string

    (** Get the native implementations (installed or candidates for installation) for this feed.
     * This default implementation finds the best <package-implementation> elements and calls [get_package_impls] on each one. *)
    method get_impls_for_feed (feed:Feed.feed) : Feed.implementation StringMap.t =
      let results = ref StringMap.empty in
      match get_matching_package_impls self feed with
      | [] -> !results
      | matches ->
          matches |> List.iter (fun (elem, props) ->
            self#get_package_impls (make_query self#fixup_main feed elem props results);
          );
          !results

    method private get_package_impls (query:query) : unit =
      let package_name = query#package_name in
      packagekit#get_impls package_name |> List.iter (fun info ->
        let id = Printf.sprintf "%s:%s:%s:%s" id_prefix package_name
          (Versions.format_version info.Packagekit.version) (default "*" info.Packagekit.machine) in
        let impl = package_impl_from_packagekit id query#elem query#props distro_name info in
        query#add_result id impl
      )

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

    (* This default implementation queries PackageKit, if available. *)
    method check_for_candidates feed =
      match get_matching_package_impls self feed with
      | [] -> Lwt.return ()
      | matches ->
          lwt available = packagekit#is_available in
          if available then (
            let package_names = matches |> List.map (fun (elem, _props) -> ZI.get_attribute "package" elem) in
            packagekit#check_for_candidates package_names
          ) else Lwt.return ()

    method install_distro_packages (ui:Ui.ui_handler) typ items : [ `ok | `cancel ] Lwt.t =
      match typ with
      | "packagekit" ->
          begin match_lwt packagekit#install_packages ui items with
          | `cancel -> Lwt.return `cancel
          | `ok ->
              items |> List.iter (fun (impl, _rm) ->
                self#fixup_main impl.Feed.props;
              );
              Lwt.return `ok end
      | _ ->
          let names = items |> List.map (fun (_impl, rm) -> snd rm.Feed.distro_install_info) in
          ui#confirm (Printf.sprintf
            "This program depends on some packages that are available through your distribution. \
             Please install them manually using %s and try again. Or, install 'packagekit' and I can \
             use that to install things. The packages are:\n\n- %s" typ (String.concat "\n- " names))
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

  let master_feed = Feed.AttrMap.find ("", "from-feed") !new_attrs in
  set "from-feed" @@ "distribution:" ^ master_feed;
  set "stability" "packaged";   (* The GUI likes to know the upstream stability too *)

  let fixup_main path =
    (* The Python code might add or modify the main executable path. *)
    let run_command =
      match StringMap.find "run" !new_props.commands with
      | Some command ->
          let new_elem = {command.command_qdom with Qdom.attrs = command.command_qdom.Qdom.attrs} in
          Qdom.set_attribute "path" path new_elem;
          {command with command_qdom = new_elem}
      | None ->
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
        | ("quick-test-file", `String v) -> set "quick-test-file" v
        | ("quick-test-mtime", `String v) -> set "quick-test-mtime" v
        | ("main", `String v) -> fixup_main v
        | (k, v) -> raise_safe "Bad JSON response '%s=%s'" k (Yojson.Basic.to_string v)
      );
      {!pkg with impl_type = PackageImpl !pkg_type; props = {!new_props with attrs = !new_attrs}}
  | _ -> raise_safe "Bad JSON: %s" (Yojson.Basic.to_string json)

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

(** Set quick-test-file and quick-test-mtime from path. *)
let get_quick_test_attrs path =
  let mtime = (Unix.stat path).Unix.st_mtime in
  Feed.AttrMap.singleton ("", "quick-test-file") path |>
  Feed.AttrMap.add ("", "quick-test-mtime") (Printf.sprintf "%.0f" mtime)

class virtual python_fallback_distribution (slave:Python.slave) python_name ctor_args =
  let make_host_impl path version ?(commands=StringMap.empty) ?(requires=[]) from_feed id =
    let host_machine = slave#config.system#platform in
    let open Feed in
    let props = {
      attrs = get_quick_test_attrs path
        |> AttrMap.add ("", FeedAttr.from_feed) (Feed_url.format_url (`distribution_feed from_feed))
        |> AttrMap.add ("", FeedAttr.id) id
        |> AttrMap.add ("", FeedAttr.stability) "packaged"
        |> AttrMap.add ("", FeedAttr.version) version;
      requires;
      bindings = [];
      commands;
    } in {
      qdom = ZI.make_root "host-package-implementation";
      props;
      stability = Packaged;
      os = None;
      machine = Some host_machine.Platform.machine;       (* (hopefully) *)
      parsed_version = Versions.parse_version version;
      impl_type = PackageImpl {
        package_distro = "host";
        package_installed = true;
        retrieval_method = None;
      }
    } in

  let did_init = ref false in

  let invoke ?xml op args process =
    lwt () =
      if not !did_init then (
        let ctor_args = ctor_args |> List.map (fun a -> `String a) in
        let r = slave#invoke_async (`List [`String "init-distro"; `String python_name; `List ctor_args]) Python.expect_null in
        did_init := true;
        r
      ) else Lwt.return () in
    slave#invoke_async ?xml (`List (`String op :: args)) process in

  let fake_host_doc = (ZI.make_root "<fake-host-root>").Qdom.doc in

  let get_host_impls = function
    | `remote_feed "http://repo.roscidus.com/python/python" as url ->
        (* Hack: we can support Python on platforms with unsupported package managers
           by adding the implementation of Python running the slave now to the list. *)
        let path, version =
          invoke "get-python-details" [] (function
            | `List [`String path; `String version] -> (path, version)
            | json -> raise_safe "Bad JSON: %s" (Yojson.Basic.to_string json)
          ) |> Lwt_main.run in
        let id = "package:host:python:" ^ version in
        let run = ZI.make_root "command" in
        run |> Q.set_attribute "name" "run";
        run |> Q.set_attribute "path" path;
        let commands = StringMap.singleton "run" Feed.({command_qdom = run; command_requires = []}) in
        [(id, make_host_impl path version ~commands url id)]
    | `remote_feed "http://repo.roscidus.com/python/python-gobject" as url ->
        let path, version =
          invoke "get-gobject-details" [] (function
            | `List [`String path; `String version] -> (path, version)
            | json -> raise_safe "Bad JSON: %s" (Yojson.Basic.to_string json)
          ) |> Lwt_main.run in
        let id = "package:host:python-gobject:" ^ version in
        let requires = [make_restricts_distro fake_host_doc "http://repo.roscidus.com/python/python" "host"] in
        [(id, make_host_impl path version ~requires url id)]
    | _ -> [] in

  let to_impls query = function
    | `List pkgs ->
        pkgs |> List.iter (fun pkg ->
          let impl = package_impl_from_json query#elem query#props pkg in
          let id = Feed.get_attr_ex FeedAttr.id impl in
          query#add_result id impl
        )
    | _ -> raise_safe "Not a group list" in

  object (self)
    inherit distribution slave#config as super

    (* Should we check for Python and GObject manually? Use [false] if the package manager
     * can be relied upon to find them. *)
    val virtual check_host_python : bool

    method! get_impls_for_feed feed =
      let impls = super#get_impls_for_feed feed in
      if check_host_python then (
        get_host_impls feed.Feed.url |> List.fold_left (fun map (id, impl) -> StringMap.add id impl map) impls
      ) else impls

    (** Gets PackageKit impls (from super), plus host Python impls, plus anything from [add_package_impls_from_python] *)
    method! private get_package_impls query =
      super#get_package_impls query;
      self#add_package_impls_from_python query

    method private add_package_impls_from_python query =
      let fake_feed = ZI.make query#feed.Feed.root.Q.doc "interface" in
      fake_feed.Q.child_nodes <- [query#elem];

      invoke ~xml:fake_feed "get-package-impls" [`String (Feed_url.format_url query#feed.Feed.url)] (function
        | `List [pkg_group] ->
            to_impls query pkg_group
        | _ -> raise_safe "Invalid response"
      ) |> Lwt_main.run

    method private invoke = invoke
  end

let is_installed config (distro:distribution) elem =
  match ZI.get_attribute_opt "quick-test-file" elem with
  | None -> distro#is_installed elem
  | Some file ->
      match config.system#stat file with
      | None -> false
      | Some info ->
          match ZI.get_attribute_opt "quick-test-mtime" elem with
          | None -> true      (* quick-test-file exists and we don't care about the time *)
          | Some required_mtime -> (Int64.of_float info.Unix.st_mtime) = Int64.of_string required_mtime

let install_distro_packages (distro:distribution) (ui:Ui.ui_handler) impls : [ `ok | `cancel ] Lwt.t =
  let groups = ref StringMap.empty in
  impls |> List.iter (fun impl ->
    match impl.Feed.impl_type with
    | Feed.PackageImpl {Feed.retrieval_method = rm; _} ->
        let rm = rm |? lazy (raise_safe "Missing retrieval method for package '%s'" (Feed.get_attr_ex FeedAttr.id impl)) in
        let (typ, _info) = rm.Feed.distro_install_info in
        let items = default [] @@ StringMap.find typ !groups in
        groups := StringMap.add typ ((impl, rm) :: items) !groups
    | _ -> raise_safe "BUG: not a PackageImpl! %s" (Feed.get_attr_ex FeedAttr.id impl)
  );

  let rec loop = function
    | [] -> Lwt.return `ok
    | (typ, items) :: groups ->
        match_lwt distro#install_distro_packages ui typ items with
        | `ok -> loop groups
        | `cancel -> Lwt.return `cancel in
  !groups |> StringMap.bindings |> loop
