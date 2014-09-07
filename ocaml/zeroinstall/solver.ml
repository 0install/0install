(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Select a compatible set of components to run a program. *)

open General
open Support.Common
module U = Support.Utils
module Qdom = Support.Qdom
module FeedAttr = Constants.FeedAttr
module AttrMap = Qdom.AttrMap

type requirements =
  | ReqCommand of (string * General.iface_uri * bool)
  | ReqIface of (General.iface_uri * bool)

module Model = struct
  module Role = struct
    type t = (iface_uri * bool)
    let to_string = function
      | iface_uri, false -> iface_uri
      | iface_uri, true -> iface_uri ^ "#source"

    (* Sort the interfaces by URI so we have a stable output. *)
    let compare (ib, sb) (ia, sa) =
      match String.compare ia ib with
      | 0 -> compare sa sb
      | x -> x
  end
  type impl = Impl.generic_implementation
  type t = Impl_provider.impl_provider
  type command = Impl.command
  type dependency = Impl.dependency
  type restriction = Impl.restriction
  type command_name = string
  type machine_group = string
  type role_information = {
    replacement : Role.t option;
    impls : impl list;
  }

  let to_string impl = (Versions.format_version impl.Impl.parsed_version) ^ " - " ^ Qdom.show_with_loc impl.Impl.qdom
  let command_to_string command = Qdom.show_with_loc command.Impl.command_qdom

  let dummy_impl =
    let open Impl in {
      qdom = ZI.make "dummy";
      os = None;
      machine = None;
      stability = Testing;
      props = {
        attrs = AttrMap.empty;
        requires = [];
        commands = StringMap.empty;   (* (not used; we can provide any command) *)
        bindings = [];
      };
      parsed_version = Versions.dummy;
      impl_type = `local_impl "/dummy";
    }

  let dummy_command = { Impl.
    command_qdom = ZI.make "dummy-command";
    command_requires = [];
    command_bindings = [];
  }

  let get_command impl name = StringMap.find name impl.Impl.props.Impl.commands

  let requires impl_provider impl = List.filter impl_provider#is_dep_needed Impl.(impl.props.requires)
  let command_requires impl_provider command = List.filter impl_provider#is_dep_needed Impl.(command.command_requires)

  let to_selection impl_provider iface commands impl =
    let attrs = Impl.(impl.props.attrs)
      |> AttrMap.remove ("", FeedAttr.stability)

      (* Replaced by <command> *)
      |> AttrMap.remove ("", FeedAttr.main)
      |> AttrMap.remove ("", FeedAttr.self_test)

      |> AttrMap.add_no_ns "interface" iface in

    let attrs =
      if Some iface = AttrMap.get_no_ns FeedAttr.from_feed attrs then (
        (* Don't bother writing from-feed attr if it's the same as the interface *)
        AttrMap.remove ("", FeedAttr.from_feed) attrs
      ) else attrs in

    let child_nodes = ref [] in
    if impl != dummy_impl then (
      let commands = List.sort compare commands in

      let copy_elem elem =
        (* Copy elem into parent (and strip out <version> elements). *)
        let open Qdom in
        let imported = {elem with
          child_nodes = List.filter (fun c -> ZI.tag c <> Some "version") elem.child_nodes;
        } in
        child_nodes := imported :: !child_nodes in

      commands |> List.iter (fun name ->
        let command = Impl.get_command_ex name impl in
        let command_elem = command.Impl.command_qdom in
        let want_command_child elem =
          (* We'll add in just the dependencies we need later *)
          match ZI.tag elem with
          | Some "requires" | Some "restricts" | Some "runner" -> false
          | _ -> true
        in
        let child_nodes = List.filter want_command_child command_elem.Qdom.child_nodes in
        let add_command_dep child_nodes dep =
          if dep.Impl.dep_importance <> Impl.Dep_restricts && impl_provider#is_dep_needed dep then
            dep.Impl.dep_qdom :: child_nodes
          else
            child_nodes in
        let child_nodes = List.fold_left add_command_dep child_nodes command.Impl.command_requires in
        let command_elem = {command_elem with Qdom.child_nodes = child_nodes} in
        copy_elem command_elem
      );

      List.iter copy_elem impl.Impl.props.Impl.bindings;
      requires impl_provider impl |> List.iter (fun dep ->
        if dep.Impl.dep_importance <> Impl.Dep_restricts then
          copy_elem (dep.Impl.dep_qdom)
      );

      impl.Impl.qdom |> ZI.iter ~name:"manifest-digest" copy_elem;
    );
    ZI.make
      ~attrs
      ~child_nodes:(List.rev !child_nodes)
      ~source_hint:impl.Impl.qdom "selection"

  let machine impl = impl.Impl.machine
  let restrictions dep = dep.Impl.dep_restrictions
  let meets_restriction impl r = impl == dummy_impl || r#meets_restriction impl
  let dep_role dep = (dep.Impl.dep_iface, false)
  let dep_required_commands dep = dep.Impl.dep_required_commands
  let dep_essential dep = dep.Impl.dep_importance = Impl.Dep_essential

  let implementations impl_provider (iface_uri, source) =
    let {Impl_provider.replacement; impls; rejects = _} = impl_provider#get_implementations iface_uri ~source in
    let replacement = replacement |> pipe_some (fun replacement ->
      if replacement = iface_uri then (
        log_warning "Interface %s replaced-by itself!" iface_uri; None
      ) else Some (replacement, source)
    ) in
    {replacement; impls}

  let impl_self_commands impl =
    Impl.(impl.props.bindings)
    |> U.filter_map (fun binding ->
      Binding.parse_binding binding
      |> pipe_some Binding.get_command
    )
  let command_self_commands command =
    command.Impl.command_bindings
    |> U.filter_map (fun binding ->
      Binding.parse_binding binding
      |> pipe_some Binding.get_command
    )
  let restricts_only dep = (dep.Impl.dep_importance = Impl.Dep_restricts)
end

module Core = Solver_core.Make(Model)

class type result =
  object
    method get_selections : Selections.t
    method get_selected : source:bool -> General.iface_uri -> Model.impl option
    method impl_provider : Impl_provider.impl_provider
    method implementations : ((General.iface_uri * bool) * (Core.diagnostics * Model.impl) option) list
    method requirements : requirements
  end

let do_solve impl_provider root_req ~closest_match =
  let root_role, root_command =
    match root_req with
    | ReqIface (iface, source) -> (iface, source), None
    | ReqCommand (command, iface, source) -> (iface, source), Some command in

  Core.do_solve impl_provider root_role ?command:root_command ~closest_match |> pipe_some (fun r ->
    (** Create a <selections> document from the result of a solve.
     * The use of Maps ensures that the inputs will be sorted, so we will have a stable output.
     *)
    let selections = r#get_selections in
    let xml_selections = Selections.create (
        let root_attrs =
          match root_req with
          | ReqCommand (command, iface, _source) ->
              AttrMap.singleton "interface" iface
              |> AttrMap.add_no_ns "command" command
          | ReqIface (iface, _source) ->
              AttrMap.singleton "interface" iface in
        let child_nodes = selections
          |> Core.RoleMap.bindings
          |> List.map (fun ((iface, _source) as role, impl) ->
            (* TODO: update selections format to handle source here *)
            let commands = r#get_commands_needed role in
            Model.to_selection impl_provider iface commands impl
          )
          |> List.rev in
        ZI.make ~attrs:root_attrs ~child_nodes "selections"
      ) in

    (* Build the results object *)
    Some (
      object (_ : result)
        method get_selections = xml_selections
        method get_selected ~source iface = r#get_selected (iface, source)
        method impl_provider = impl_provider
        method implementations = r#implementations
        method requirements = root_req
      end
    )
  )

let explain = Core.explain
type diagnostics = Core.diagnostics

let get_root_requirements config requirements =
  let { Requirements.command; interface_uri; source; extra_restrictions; os; cpu; message = _ } = requirements in

  (* This is for old feeds that have use='testing' instead of the newer
    'test' command for giving test-only dependencies. *)
  let use = if command = Some "test" then StringSet.singleton "testing" else StringSet.empty in

  let platform = config.system#platform in
  let os = default platform.Platform.os os in
  let machine = default platform.Platform.machine cpu in

  (* Disable multi-arch on Linux if the 32-bit linker is missing. *)
  let multiarch = os <> "Linux" || config.system#file_exists "/lib/ld-linux.so.2" in

  let scope_filter = Impl_provider.({
    extra_restrictions = StringMap.map Impl.make_version_restriction extra_restrictions;
    os_ranks = Arch.get_os_ranks os;
    machine_ranks = Arch.get_machine_ranks ~multiarch machine;
    languages = config.langs;
    allowed_uses = use;
  }) in

  let root_req = match command with
  | Some command -> ReqCommand (command, interface_uri, source)
  | None -> ReqIface (interface_uri, source) in

  (scope_filter, root_req)

let solve_for config feed_provider requirements =
  try
    let scope_filter, root_req = get_root_requirements config requirements in

    let impl_provider = (new Impl_provider.default_impl_provider config feed_provider scope_filter :> Impl_provider.impl_provider) in
    match do_solve impl_provider root_req ~closest_match:false with
    | Some result -> (true, result)
    | None ->
        match do_solve impl_provider root_req ~closest_match:true with
        | Some result -> (false, result)
        | None -> failwith "No solution, even with closest_match!"
  with Safe_exception _ as ex -> reraise_with_context ex "... solving for interface %s" requirements.Requirements.interface_uri
