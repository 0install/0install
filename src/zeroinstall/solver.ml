(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Select a compatible set of components to run a program. 
 * This instantiates the [Solver_core] functor with the concrete 0install types. *)

open General
open Support
open Support.Common
module U = Support.Utils
module Qdom = Support.Qdom
module FeedAttr = Constants.FeedAttr
module AttrMap = Qdom.AttrMap

type scope = Impl_provider.impl_provider
type role = {
  scope : scope;
  iface : Sigs.iface_uri;
  source : bool;
}

module Input = struct
  (** See [Solver_types.MODEL] for documentation. *)

  module Role = struct
    (** A role is an interface and a flag indicating whether we want source or a binary.
     * This allows e.g. using an old version of a compiler to compile the source for the
     * new version (which requires selecting two different versions of the same interface). *)
    type t = role
    let pp f = function
      | {iface; source = false; _} -> Format.pp_print_string f iface
      | {iface; source = true; _} -> Format.fprintf f "%s#source" iface

    (* Sort the interfaces by URI so we have a stable output. *)
    let compare role_a role_b =
      match String.compare role_a.iface role_b.iface with
      | 0 -> compare role_a.source role_b.source
      | x -> x
  end
  type impl = Impl.generic_implementation
  type command = Impl.command
  type restriction = Impl.restriction
  type command_name = string
  type rejection = Impl_provider.rejection_reason
  type dependency = Role.t * Impl.dependency
  type machine_group = string
  type dep_info = {
    dep_role : Role.t;
    dep_importance : [ `Essential | `Recommended | `Restricts ];
    dep_required_commands : command_name list;
  }
  type role_information = {
    replacement : Role.t option;
    impls : impl list;
  }
  type requirements = {
    role : Role.t;
    command : command_name option;
  }

  let pp_impl f impl = Format.fprintf f "%a-%a" Version.pp impl.Impl.parsed_version Impl.pp impl
  let id_of_impl impl = Impl.get_attr_ex FeedAttr.id impl
  let pp_command f command = Element.pp f command.Impl.command_qdom
  let describe_problem = Impl_provider.describe_problem

  let pp_version f impl = Version.pp f impl.Impl.parsed_version

  let pp_impl_long f impl =
    let id = id_of_impl impl in
    let id = if String.length id > 20 then String.sub id 0 17 ^ "..." else id in
    Format.fprintf f "v%a (%s)" pp_version impl id

  let compare_version a b = compare a.Impl.parsed_version b.Impl.parsed_version

  let dummy_impl =
    Impl.make
      ~elem:(Element.make_impl Qdom.AttrMap.empty)
      ~os:None ~machine:None
      ~stability:Stability.Testing
      ~props:{ Impl.
        attrs = AttrMap.empty;
        requires = [];
        commands = XString.Map.empty;   (* (not used; we can provide any command) *)
        bindings = [];
      }
      ~version:(Version.parse "0")
      (`Local_impl "/dummy")

  let dummy_command = { Impl.
    command_qdom = Element.make_command ~source_hint:None "dummy-command";
    command_requires = [];
    command_bindings = [];
  }

  let get_command impl name =
    if impl == dummy_impl then Some dummy_command
    else XString.Map.find_opt name impl.Impl.props.Impl.commands

  let make_deps role zi_deps self_bindings =
    let impl_provider = role.scope in
    let deps = zi_deps
      |> List.filter_map (fun zi_dep ->
        if impl_provider#is_dep_needed zi_dep then Some (role, zi_dep)
        else None
      ) in
    let self_commands = self_bindings
      |> List.filter_map (fun binding ->
        Element.classify_binding binding |> Binding.parse_binding |> Binding.get_command
      ) in
    (deps, self_commands)

  let dep_info (role, dep) = {
    dep_role = {scope = role.scope; iface = dep.Impl.dep_iface; source = dep.Impl.dep_src};
    dep_importance = dep.Impl.dep_importance;
    dep_required_commands = dep.Impl.dep_required_commands;
  }

  let restrictions (_role, dep) = dep.Impl.dep_restrictions

  let requires role impl = make_deps role Impl.(impl.props.requires) Impl.(impl.props.bindings)
  let command_requires role command = make_deps role Impl.(command.command_requires) Impl.(command.command_bindings)

  let machine_group impl =
    match Arch.get_machine_group impl.Impl.machine with
    | None -> None
    | Some Arch.Machine_group_default -> Some "def"
    | Some Arch.Machine_group_64 -> Some "64"

  let format_machine impl =
    match impl.Impl.machine with
    | None -> "any"
    | Some machine -> Arch.format_machine machine

  let meets_restriction impl r = impl == dummy_impl || r#meets_restriction impl
  let string_of_restriction r = r#to_string

  let implementations {scope = impl_provider; iface; source} =
    let {Impl_provider.replacement; impls; rejects = _; compare = _; feed_problems = _} =
      impl_provider#get_implementations iface ~source in
    let replacement = replacement |> pipe_some (fun replacement ->
      if replacement = iface then (
        log_warning "Interface %s replaced-by itself!" iface; None
      ) else Some {scope = impl_provider; iface = replacement; source}
    ) in
    {replacement; impls}

  let rejects {scope = impl_provider; iface; source} =
    let candidates = impl_provider#get_implementations iface ~source in
    (candidates.Impl_provider.rejects, candidates.Impl_provider.feed_problems)

  let user_restrictions role =
    XString.Map.find_opt role.iface role.scope#extra_restrictions

  type conflict_class = private string
  let conflict_class _ = []
end

include Zeroinstall_solver.Make(Input)

let to_xml role sel =
  let impl = Output.unwrap sel in
  let commands = Output.selected_commands sel in
  let open Input in
  let {scope = impl_provider; iface; source = _} = role in
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

  let attrs =
    match impl.Impl.impl_type with
    | `Binary_of _ -> AttrMap.add_no_ns "requires-compilation" "true" attrs
    | _ -> attrs in

  let child_nodes = ref [] in
  if impl != dummy_impl then (
    let commands = List.sort compare commands in

    let copy_qdom elem =
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
      let child_nodes = List.filter want_command_child (Element.as_xml command_elem).Qdom.child_nodes in
      let add_command_dep child_nodes dep =
        if dep.Impl.dep_importance <> `Restricts && impl_provider#is_dep_needed dep then
          Element.as_xml dep.Impl.dep_qdom :: child_nodes
        else
          child_nodes in
      let child_nodes = List.fold_left add_command_dep child_nodes command.Impl.command_requires in
      let command_elem = {(Element.as_xml command_elem) with Qdom.child_nodes = child_nodes} in
      copy_qdom command_elem
    );

    let copy_elem elem =
      copy_qdom (Element.as_xml elem) in

    Impl.(impl.props.bindings) |> List.iter copy_elem;
    Impl.(impl.props.requires) |> List.iter (fun dep ->
      if impl_provider#is_dep_needed dep && dep.Impl.dep_importance <> `Restricts then
        copy_elem (dep.Impl.dep_qdom)
    );

    begin match impl.Impl.impl_type with
    | `Cache_impl {Impl.digests = []; _} -> ()  (* todo: Shouldn't really happen *)
    | `Cache_impl {Impl.digests; _} ->
        let rec aux attrs = function
          | [] -> attrs
          | (name, value) :: ds -> aux (Qdom.AttrMap.add_no_ns name value attrs) ds in
        let attrs = aux Qdom.AttrMap.empty digests in
        let manifest_digest =
          ZI.make ~attrs ~source_hint:(Element.as_xml impl.Impl.qdom) "manifest-digest" in
        child_nodes := manifest_digest :: !child_nodes
    | `Local_impl _ | `Package_impl _ | `Binary_of _ -> () end
  );
  ZI.make
    ~attrs
    ~child_nodes:(List.rev !child_nodes)
    ~source_hint:(Element.as_xml impl.Impl.qdom) "selection"

let impl_provider role = role.scope

let get_root_requirements config requirements make_impl_provider =
  let { Requirements.command; interface_uri; source; may_compile; extra_restrictions; os; cpu; message = _ } = requirements in

  (* This is for old feeds that have use='testing' instead of the newer
    'test' command for giving test-only dependencies. *)
  let use = if command = Some "test" then XString.Set.singleton "testing" else XString.Set.empty in

  let (host_os, host_machine) = Arch.platform config.system in
  let os = default host_os os in
  let machine = default host_machine cpu in

  (* Disable multi-arch on Linux if the 32-bit linker is missing. *)
  let multiarch = os <> Arch.linux || config.system#file_exists "/lib/ld-linux.so.2" in

  let scope_filter = { Scope_filter.
    extra_restrictions = XString.Map.map Impl.make_version_restriction extra_restrictions;
    os_ranks = Arch.get_os_ranks os;
    machine_ranks = Arch.get_machine_ranks ~multiarch machine;
    languages = config.langs;
    allowed_uses = use;
    may_compile;
  } in

  let impl_provider = make_impl_provider scope_filter in
  let root_role = {scope = impl_provider; iface = interface_uri; source} in
  {Input.command; role = root_role}

let solve_for config feed_provider requirements =
  try
    let make_impl_provider scope_filter = new Impl_provider.default_impl_provider config feed_provider scope_filter in
    let root_req = get_root_requirements config requirements make_impl_provider in

    match do_solve root_req ~closest_match:false with
    | Some result -> (true, result)
    | None ->
        match do_solve root_req ~closest_match:true with
        | Some result -> (false, result)
        | None -> failwith "No solution, even with closest_match!"
  with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... solving for interface %s" requirements.Requirements.interface_uri

(** Create a <selections> document from the result of a solve.
 * The use of Maps ensures that the inputs will be sorted, so we will have a stable output.
 *)
let selections result =
  Selections.create (
    let open Input in
    let root_attrs =
      let root_req = Output.requirements result in
      begin match root_req.command with
      | Some command -> AttrMap.singleton "command" command
      | None -> AttrMap.empty end
      |> AttrMap.add_no_ns "interface" root_req.role.iface
      |> AttrMap.add_no_ns "source" (string_of_bool root_req.role.source) in
    let child_nodes = Output.to_map result
      |> Output.RoleMap.bindings
      |> List.map (fun (role, selection) -> to_xml role selection) in
    ZI.make ~attrs:root_attrs ~child_nodes "selections"
  )

module Diagnostics = Zeroinstall_solver.Diagnostics(Output)

(** Return a message explaining why the solve failed. *)
let get_failure_reason config result =
  let verbose = Support.Logging.(will_log Debug) in
  let msg = Diagnostics.get_failure_reason ~verbose result in
  if config.network_use = Offline then
    msg ^ "\nNote: 0install is in off-line mode"
  else
    msg
