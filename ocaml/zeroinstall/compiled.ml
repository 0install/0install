(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
open Support.Common
module Q = Support.Qdom
module U = Support.Utils

let compile_if_0install_version = (COMPILE_NS.ns, Constants.FeedAttr.if_0install_version)

let compile_binary_main = Q.AttrMap.get (COMPILE_NS.ns, "binary-main")
let compile_binary_lib_mappings = Q.AttrMap.get (COMPILE_NS.ns, "binary-lib-mappings")

(** Convert compile:if-0install-version attributes to plain if-0install-version *)
let rec arm_if_0install_attrs elem =
  let attrs =
    match elem.Q.attrs |> Q.AttrMap.get compile_if_0install_version with
    | None ->
        elem.Q.attrs
    | Some expr ->
        elem.Q.attrs
        |> Q.AttrMap.remove compile_if_0install_version
        |> Q.AttrMap.add_no_ns Constants.FeedAttr.if_0install_version expr in
  { elem with Q.
    attrs;
    child_nodes = List.map arm_if_0install_attrs elem.Q.child_nodes
  }

let make_binary_element ~id ~host_arch ~version ~src_impl command =
  let src_attrs = Impl.(src_impl.props.attrs) in
  let source_hint, child_nodes, template_attrs, arch =
    match Element.compile_template command.Impl.command_qdom with
    | Some impl_template ->
        let template_xml = Element.as_xml impl_template |> arm_if_0install_attrs in
        (template_xml, template_xml.Q.child_nodes, template_xml.Q.attrs, Element.arch impl_template)
    | None -> 
        (Element.as_xml command.Impl.command_qdom, [], Q.AttrMap.empty, None)
  in

  let add_arch attrs =
    match arch with
    | Some "*-*" -> attrs |> Q.AttrMap.remove ("", "arch")   (* Feed says it will make a portable binary *)
    | Some arch -> attrs |> Q.AttrMap.add_no_ns "arch" arch
    | None -> attrs |> Q.AttrMap.add_no_ns "arch" (Arch.format_arch host_arch) in

  let add_license attrs =
    if Q.AttrMap.mem ("", Constants.FeedAttr.license) attrs then attrs
    else (
      match Q.AttrMap.get_no_ns Constants.FeedAttr.license Impl.(src_impl.props.attrs) with
      | None -> attrs
      | Some license -> attrs |> Q.AttrMap.add_no_ns Constants.FeedAttr.license license
    ) in

  (* Use the deprecated binary-main attribute, if present (and we didn't override it
   * with the newer impl_template feature). *)
  let attrs =
    match compile_binary_main src_attrs with
    | Some main when not (Q.AttrMap.mem ("", "main") template_attrs) ->
        template_attrs |> Q.AttrMap.add_no_ns "main" main
    | _ ->
        template_attrs in

  (* Copy the (deprecated) binary-lib-mappings to lib-mappings. *)
  let attrs =
    match compile_binary_lib_mappings src_attrs with
    | None -> attrs
    | Some mappings ->
        attrs |> Q.AttrMap.add ~prefix:"compile" (COMPILE_NS.ns, "lib-mappings") mappings in

  (* Source dependencies tagged with binary-include. *)
  let extra_binary_reqs =
    Impl.(src_impl.props.requires) |> U.filter_map (fun req ->
      let elem = req.Impl.dep_qdom in
      if Element.compile_include_binary elem = Some true then (
        let elem = Element.as_xml elem in
        Some {elem with Q.attrs = elem.Q.attrs |> Q.AttrMap.remove (COMPILE_NS.ns, "include-binary")}
      ) else None
    ) in

  (* We don't need to handle compile:pin-components here because it's up to the compiler to build
   * something compatible with the binaries we choose. *)

  Element.make_impl
    ~source_hint
    ~child_nodes:(extra_binary_reqs @ child_nodes)
    (attrs
      |> Q.AttrMap.add_no_ns "id" id
      |> Q.AttrMap.add_no_ns "version" version
      |> add_arch
      |> add_license
    )

let of_source ~host_arch impl =
  let open Impl in
  let local_dir = local_dir_of impl in
  let props = impl.props in
  match StringMap.find "compile" props.commands with
  | None -> `Reject `No_compile_command
  | Some command ->
  let id = get_attr_ex "id" impl in
  let bin_element =
    make_binary_element
      ~id
      ~host_arch
      ~version:(get_attr_ex "version" impl)
      ~src_impl:impl
      command in
  match Element.filter_if_0install_version bin_element with
  | None -> `Filtered_out
  | Some bin_element ->
  let os, machine = host_arch in
  let props = Feed.process_group_properties ~local_dir {
    attrs = Feed.default_attrs ~url:(Impl.get_attr_ex Constants.FeedAttr.from_feed impl);
    requires = [];
    bindings = [];
    commands = StringMap.empty;
  } bin_element in
  `Ok (Impl.make
         ~elem:bin_element
         ~props
         ~stability:impl.stability
         ~os ~machine
         ~version:impl.parsed_version
         (`Binary_of impl)
      )
