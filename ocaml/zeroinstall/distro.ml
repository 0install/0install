(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interacting with distribution package managers. *)

open General
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
  elem : [`Package_impl] Element.t; (* The <package-element> which generated this query *)
  package_name : string;            (* The 'package' attribute on the <package-element> *)
  elem_props : Impl.properties;     (* Properties on or inherited by the <package-element> - used by [add_package_implementation] *)
  feed : Feed.feed;                 (* The feed containing the <package-element> *)
  results : Impl.distro_implementation Support.Common.StringMap.t ref;
  problem : string -> unit;
}

let make_query feed elem elem_props results problem = {
  elem;
  package_name = Element.package elem;
  elem_props;
  feed;
  results;
  problem;
}

type quick_test_condition = Exists | UnchangedSince of float
type quick_test = (Support.Common.filepath * quick_test_condition)

class type virtual provider =
  object
    method match_name : string -> bool
    method is_installed : Selections.selection -> bool
    method get_impls_for_feed :
      ?init:(Impl.distro_implementation Support.Common.StringMap.t) ->
      problem:(string -> unit) ->
      Feed.feed ->
      Impl.distro_implementation Support.Common.StringMap.t
    method virtual check_for_candidates : 'a. ui:(#Packagekit.ui as 'a) -> Feed.feed -> unit Lwt.t
    method install_distro_packages : 'a. (#Packagekit.ui as 'a) -> string -> (Impl.distro_implementation * Impl.distro_retrieval_method) list -> [ `Ok | `Cancel ] Lwt.t
    method is_valid_package_name : string -> bool
  end

class virtual distribution config =
  let system = config.system in
  let host_python = Host_python.make system in
  object (self : #provider)
    val virtual distro_name : string
    val virtual check_host_python : bool
    val system_paths = ["/usr/bin"; "/bin"; "/usr/sbin"; "/sbin"]

    val valid_package_name = Str.regexp "^[^.-][^/]*$"

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

    method private fixup_main impl =
      let open Impl in
      match get_command_opt "run" impl with
      | None -> ()
      | Some run ->
          match self#get_correct_main impl run with
          | None -> ()
          | Some new_main -> run.command_qdom <- Element.make_command ~path:new_main ~source_hint:None "run"

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
                  {command with command_qdom = Element.make_command ~path ~source_hint:None "run"}
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
      let impl =
        Impl.make
          ~elem
          ~os:None
          ~machine
          ~stability:Stability.Packaged
          ~props:{props with Impl.attrs = !new_attrs}
          ~version
          (`Package_impl { Impl.package_state; package_distro = distro_name })
      in
      if package_state = `Installed then self#fixup_main impl;
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
            | `Distribution_feed master_feed -> master_feed
            | `Local_feed _ | `Remote_feed _ -> assert false in
      match Feed_cache.get_cached_feed config master_feed with
      | None -> false
      | Some master_feed ->
          let wanted_id = Element.id elem in
          let impls = self#get_impls_for_feed ~problem:ignore master_feed in
          match StringMap.find wanted_id impls with
          | None -> false
          | Some {Impl.impl_type = `Package_impl {Impl.package_state; _}; _} -> package_state = `Installed

    (** Get the native implementations (installed or candidates for installation) for this feed.
     * This default implementation finds the best <package-implementation> elements and calls [get_package_impls] on each one. *)
    method get_impls_for_feed ?(init=StringMap.empty) ~problem (feed:Feed.feed) : Impl.distro_implementation StringMap.t =
      let results = ref init in

      if check_host_python then (
        Host_python.get host_python feed.Feed.url |> List.iter (fun (id, impl) -> results := StringMap.add id impl !results)
      );

      match get_matching_package_impls self feed with
      | [] -> !results
      | matches ->
          matches |> List.iter (fun (elem, props) ->
            self#get_package_impls (make_query feed elem props results problem);
          );
          !results

    method virtual private get_package_impls : query -> unit

    (** Called when an installed package is added, or when installation completes. This is useful to fix up the main value.
        The default implementation checks that main exists, and searches [system_paths] for
        it if not. *)
    method private get_correct_main (_impl:Impl.distro_implementation) run_command =
      let open Impl in
      Element.path run_command.command_qdom |> pipe_some (fun path ->
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

    method virtual check_for_candidates : 'a. ui:(#Packagekit.ui as 'a) -> Feed.feed -> unit Lwt.t

    method install_distro_packages : 'a. (#Packagekit.ui as 'a) -> string ->
        (Impl.distro_implementation * Impl.distro_retrieval_method) list -> [ `Ok | `Cancel ] Lwt.t =
      fun ui typ items ->
        let names = items |> List.map (fun (_impl, rm) -> snd rm.Impl.distro_install_info) in
        ui#confirm (Printf.sprintf
          "This program depends on some packages that are available through your distribution. \
           Please install them manually using %s before continuing. The packages are:\n\n- %s"
           typ
           (String.concat "\n- " names))
  end

type t = distribution

let of_provider t = (t :> distribution)

let install_distro_packages (t:t) ui impls : [ `Ok | `Cancel ] Lwt.t =
  let groups = ref StringMap.empty in
  impls |> List.iter (fun impl ->
    let `Package_impl {Impl.package_state; _} = impl.Impl.impl_type in
    match package_state with
    | `Installed -> raise_safe "BUG: package %s already installed!" (Impl.get_id impl).Feed_url.id
    | `Uninstalled rm ->
        let (typ, _info) = rm.Impl.distro_install_info in
        let items = default [] @@ StringMap.find typ !groups in
        groups := StringMap.add typ ((impl, rm) :: items) !groups
  );

  let rec loop = function
    | [] -> Lwt.return `Ok
    | (typ, items) :: groups ->
        t#install_distro_packages ui typ items >>= function
        | `Ok -> loop groups
        | `Cancel -> Lwt.return `Cancel in
  !groups |> StringMap.bindings |> loop

let get_impls_for_feed t = t#get_impls_for_feed
let check_for_candidates (t:t) ~ui feed = t#check_for_candidates ~ui feed

let is_installed (t:t) config elem =
  match Element.quick_test_file elem with
  | None ->
      let package_name = Element.package elem in
      t#is_valid_package_name package_name && t#is_installed elem
  | Some file ->
      match config.system#stat file with
      | None -> false
      | Some info ->
          match Element.quick_test_mtime elem with
          | None -> true      (* quick-test-file exists and we don't care about the time *)
          | Some required_mtime -> (Int64.of_float info.Unix.st_mtime) = required_mtime
