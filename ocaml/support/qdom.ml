(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Common;;

(** An XML element node, including nearby text. *)
type element = {
  tag: Xmlm.name;
  mutable attrs: Xmlm.attribute list;
  mutable child_nodes: element list;
  mutable text_before: string;        (** The text node immediately before us *)
  mutable last_text_inside: string;   (** The last text node inside us with no following element *)
  source_name: filepath option;       (** For error messages *)
  pos: Xmlm.pos;                      (** Location of element in XML *)
};;

let parse_input source_name i = try (
  (* Parse all elements from here to the next close tag and return those elements *)
  let rec parse_nodes i prev_siblings prev_text =
    if Xmlm.eoi i then
      (prev_siblings, prev_text)
    else
      let pos = Xmlm.pos i in
      match Xmlm.input i with
        | `Data s -> parse_nodes i prev_siblings (prev_text ^ s)
        | `Dtd _dtd -> parse_nodes i prev_siblings prev_text
        | `El_end -> (prev_siblings, prev_text)
        | `El_start (tag, attrs) -> (
          let child_nodes, trailing_text = parse_nodes i [] "" in
          let new_node = {
            tag = tag;
            attrs = attrs;
            child_nodes = List.rev child_nodes;
            text_before = prev_text;
            last_text_inside = trailing_text;
            source_name = Some source_name;
            pos;
          } in parse_nodes i (new_node :: prev_siblings) ""
        )
  in

  match parse_nodes i [] "" with
  | [root], "" -> root
  | _ -> failwith("Expected single root node in XML")
) with Xmlm.Error ((line, col), err) ->
  raise_safe "[%d:%d] %s" line col (Xmlm.error_message err)
;;

let parse_file (system:system) path =
  try system#with_open_in [Open_rdonly; Open_binary] 0 path (fun ch ->
    parse_input path (Xmlm.make_input (`Channel ch))
  )
  with
  | Safe_exception _ as ex -> reraise_with_context ex "... parsing XML document %s" path
  | Sys_error msg -> raise_safe "Error parsing XML document '%s': %s" path msg

(** Helper functions. *)

let find pred node =
  try Some (List.find pred node.child_nodes)
  with Not_found -> None
;;

let show_with_loc elem =
  let (_ns, name) = elem.tag in
  let (line, col) = elem.pos in
  match elem.source_name with
  | Some path -> Printf.sprintf "<%s> at %s:%d:%d" name path line col
  | None -> Printf.sprintf "<%s> (generated)" name
;;

module type NsType = sig
  val ns : string;;
end;;

let raise_elem fmt =
  let do_raise s elem : 'b =
    raise_safe "%s %s" s @@ show_with_loc elem
  in Printf.ksprintf do_raise fmt

let log_elem level =
  let do_log s elem =
    Logging.log level "%s %s" s (show_with_loc elem)
  in Printf.ksprintf do_log

let simple_content element =
  if element.child_nodes = [] then
    element.last_text_inside
  else
    raise_elem "Non-text child nodes not permitted inside" element

module NsQuery (Ns : NsType) = struct
  (** Return the localName part of this element's tag.
      Throws an exception if it's in the wrong namespace. *)
  let tag elem =
    let (elem_ns, name) = elem.tag in
    if elem_ns = Ns.ns then Some name
    else None

  let map ~f node tag =
    let rec loop = function
      | [] -> []
      | (node::xs) ->
          if node.tag = (Ns.ns, tag)
          then let result = f node in result :: loop xs
          else loop xs in
    loop node.child_nodes
  ;;

  let filter_map ~f node tag =
    let rec loop = function
      | [] -> []
      | (node::xs) ->
          if node.tag = (Ns.ns, tag) then (
            match f node with
            | None -> loop xs
            | Some result -> result :: loop xs
          ) else loop xs in
    loop node.child_nodes
  ;;

  let check_ns elem =
    let (ns, _) = elem.tag in
    if ns = Ns.ns then ()
    else raise_elem "Element not in namespace %s:" Ns.ns elem
  ;;

  let get_attribute attr elem = try
      check_ns elem;
      List.assoc ("", attr) elem.attrs
    with
      Not_found -> raise_elem "Missing attribute '%s' on" attr elem
  ;;

  let get_attribute_opt attr elem = try
      check_ns elem;
      Some (List.assoc ("", attr) elem.attrs)
    with
      Not_found -> None
  ;;

  let iter ~f node =
    let fn2 elem =
      let (ns, _) = elem.tag in
      if ns = Ns.ns then f elem else ()
    in List.iter fn2 node.child_nodes
  ;;

  let iter_with_name ~f node tag =
    let fn2 elem = if elem.tag = (Ns.ns, tag) then f elem else () in
    List.iter fn2 node.child_nodes
  ;;

  let fold_left ~f init node tag =
    let fn2 m elem = if elem.tag = (Ns.ns, tag) then f m elem else m in
    List.fold_left fn2 init node.child_nodes
  ;;

  let check_tag expected elem =
    let (ns, name) = elem.tag in
    if ns <> Ns.ns then raise_elem "Element not in namespace %s:" Ns.ns elem
    else if name <> expected then raise_elem "Expected <%s> but found " expected elem
    else ()

  let make tag = {
    tag = (Ns.ns, tag);
    attrs = [];
    child_nodes = [];
    text_before = "";
    last_text_inside = "";
    source_name = None;
    pos = (0, 0);
  }
end;;
