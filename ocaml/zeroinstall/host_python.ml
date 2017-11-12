(* Copyright (C) 2017, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
open Support.Common

module Q = Support.Qdom
module FeedAttr = Constants.FeedAttr

type info = {
  path : filepath;
  version : string;
}

type package_set = {
  python : info;
  python_gobject : info option;
}

type t = {
  host_machine : Arch.machine;
  python_installations : package_set list Lazy.t;
}

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

(** Get quick-test-file and quick-test-mtime from path. *)
let get_quick_test_attrs path =
  let mtime =
    (* Ensure we round the same way as in [is_installed_quick] *)
    (Unix.stat path).Unix.st_mtime
    |> Int64.of_float
    |> Int64.to_string in
  Q.AttrMap.empty
  |> Q.AttrMap.add_no_ns FeedAttr.quick_test_file path
  |> Q.AttrMap.add_no_ns FeedAttr.quick_test_mtime mtime

let make_restricts_distro iface_uri distros = { Impl.
    dep_qdom = Element.dummy_restricts;
    dep_importance = `Restricts;
    dep_iface = iface_uri;
    dep_src = false;
    dep_restrictions = [Impl.make_distribtion_restriction distros];
    dep_required_commands = [];
    dep_if_os = None;
    dep_use = None;
  }

let info_of_json = function
  | `List [`String path; `String version] -> {path; version}
  | json -> raise_safe "Bad JSON: '%s'" (Yojson.Basic.to_string json)

let make system =
  let (_host_os, host_machine) = Arch.platform system in
  let python_installations = lazy (
    ["python"; "python2"; "python3"] |> Utils.filter_map (fun name ->
        Utils.find_in_path system name |> pipe_some (fun path ->
            try
              let json = [path; "-c"; python_test_code] |> Utils.check_output system Yojson.Basic.from_channel in
              match json with
              | `List [python_json; gobject_json] ->
                let python = info_of_json python_json in
                let python_gobject =
                  match gobject_json with
                  | `Null -> None
                  | json -> Some (info_of_json json)
                in
                Some {python; python_gobject}
              | _ -> raise_safe "Bad JSON: '%s'" (Yojson.Basic.to_string json)
            with ex -> log_warning ~ex "Failed to get details from Python"; None
          )
      )
  ) in
  { python_installations; host_machine }

let make_host_impl t path version ~package ?(commands=StringMap.empty) ?(requires=[]) from_feed id =
  let props = { Impl.
    attrs = get_quick_test_attrs path
      |> Q.AttrMap.add_no_ns FeedAttr.from_feed (Feed_url.format_url (`Distribution_feed from_feed))
      |> Q.AttrMap.add_no_ns FeedAttr.id id
      |> Q.AttrMap.add_no_ns FeedAttr.stability "packaged"
      |> Q.AttrMap.add_no_ns FeedAttr.version version
      |> Q.AttrMap.add_no_ns FeedAttr.package package;
    requires;
    bindings = [];
    commands;
  } in
  Impl.make
    ~elem:(Element.make_impl Q.AttrMap.empty)
    ~props
    ~stability:Stability.Packaged
    ~os:None
    ~machine:(Some t.host_machine)       (* (hopefully) *)
    ~version:(Version.parse version)
    (`Package_impl { Impl.
                     package_distro = "host";
                     package_state = `Installed;
                   }
    )

let get t = function
  | `Remote_feed "http://repo.roscidus.com/python/python" as url ->
      (* We support Python on platforms with unsupported package managers
         by running it manually and parsing the output. Ideally we would
         cache this information on disk. *)
      Lazy.force t.python_installations |> List.map (fun installation ->
        let {path; version} = installation.python in
        let id = "package:host:python:" ^ version in
        let run = Impl.make_command "run" path in
        let commands = StringMap.singleton "run" run in
        (id, make_host_impl t ~package:"host-python" path version ~commands url id)
      )
  | `Remote_feed "http://repo.roscidus.com/python/python-gobject" as url ->
      Lazy.force t.python_installations |> Utils.filter_map (fun installation ->
        match installation.python_gobject with
        | Some info ->
            let id = "package:host:python-gobject:" ^ info.version in
            let requires = [make_restricts_distro "http://repo.roscidus.com/python/python" "host"] in
            Some (id, make_host_impl t ~package:"host-python-gobject" info.path info.version ~requires url id)
        | None -> None
      )
  | _ -> []
