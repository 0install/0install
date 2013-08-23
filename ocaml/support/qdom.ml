(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Common;;

type document = {
  source_name : filepath option;       (** For error messages *)
  mutable prefixes : string StringMap.t;
}

(** An XML element node, including nearby text. *)
type element = {
  tag: Xmlm.name;
  mutable attrs: Xmlm.attribute list;
  mutable child_nodes: element list;
  mutable text_before: string;        (** The text node immediately before us *)
  mutable last_text_inside: string;   (** The last text node inside us with no following element *)
  doc: document;
  pos: Xmlm.pos;                      (** Location of element in XML *)
};;

(** When serialising the document, use [prefix] as the prefix for the namespace [uri].
    If [prefix] is already registered, find a free name ([prefix1], [prefix2], etc). *)
let register_prefix doc prefix uri =
  let p = ref prefix in
  let i = ref 0 in
  while StringMap.mem !p doc.prefixes do
    i := !i + 1;
    p := prefix ^ (string_of_int !i)
  done;
  (* log_info "New prefix: %s -> %s" !p uri; *)
  doc.prefixes <- StringMap.add !p uri doc.prefixes

let parse_input source_name i = try (
  let doc = {
    source_name;
    prefixes = StringMap.empty;
  } in

  let extract_namespaces attrs =
    ListLabels.filter attrs ~f:(fun ((ns, name), value) ->
      if ns = Xmlm.ns_xmlns then (
        register_prefix doc name value;
        false
      ) else true
    ) in

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
          let attrs = extract_namespaces attrs in
          let new_node = {
            tag = tag;
            attrs = attrs;
            child_nodes = List.rev child_nodes;
            text_before = prev_text;
            last_text_inside = trailing_text;
            doc;
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
    parse_input (Some path) (Xmlm.make_input (`Channel ch))
  )
  with
  | Safe_exception _ as ex -> reraise_with_context ex "... parsing XML document %s" path
  | Sys_error msg -> raise_safe "Error parsing XML document '%s': %s" path msg

(** Helper functions. *)

let find pred node =
  try Some (List.find pred node.child_nodes)
  with Not_found -> None
;;

(** [prepend_child child parent] makes [child] the first child of [parent]. *)
let prepend_child child parent =
  assert (child.doc == parent.doc);
  parent.child_nodes <- child :: parent.child_nodes

(** [import_node node doc] makes a copy of [node] for use in [doc]. *)
let import_node elem doc =
  let ensure_prefix prefix uri =
    let current =
      try Some (StringMap.find prefix doc.prefixes)
      with Not_found -> None in
    if current <> Some uri then
      register_prefix doc prefix uri in
  StringMap.iter ensure_prefix elem.doc.prefixes;
  let rec imp node = {node with
      doc = doc;
      child_nodes = List.map imp node.child_nodes;
      pos = (-1, -1);
    } in
  imp elem

let show_with_loc elem =
  let (_ns, name) = elem.tag in
  let (line, col) = elem.pos in
  match elem.doc.source_name with
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

let output o root =
  let root_attrs = ref root.attrs in
  StringMap.iter (fun k v -> root_attrs := ((Xmlm.ns_xmlns, k), v) :: !root_attrs) root.doc.prefixes;
    
  Xmlm.output o @@ `Dtd None;
  let rec output_node node =
    if node.text_before <> "" then Xmlm.output o @@ `Data node.text_before;
    Xmlm.output o @@ `El_start (node.tag, node.attrs);
    List.iter output_node node.child_nodes;
    if node.last_text_inside <> "" then Xmlm.output o @@ `Data node.last_text_inside;
    Xmlm.output o @@ `El_end in
  output_node {root with attrs = !root_attrs}

let to_utf8 elem =
  let buf = Buffer.create 1000 in
  let out = Xmlm.make_output @@ `Buffer buf in
  output out elem;
  Buffer.contents buf

let get_attribute_opt attr elem =
  try
    Some (List.assoc attr elem.attrs)
  with
    Not_found -> None

let set_attribute name value element =
  let pair = ("", name) in
  element.attrs <- (pair, value) :: List.remove_assoc pair element.attrs

let reindent root =
  let rec process indent node =
    node.text_before <- indent ^ (trim node.text_before);
    if node.child_nodes <> [] then (
      List.iter (process @@ indent ^ "  ") node.child_nodes;
      node.last_text_inside <- (trim node.last_text_inside) ^ indent;
    )
    in
  process "\n" root;
  root.text_before <- "";

exception Compare_result of int

module AttrSet = Set.Make(
  struct
    type t = (Xmlm.name * string)
    let compare a b = compare a b
  end
)

let set_of_attrs elem : AttrSet.t =
  List.fold_left (fun set attr -> AttrSet.add attr set) AttrSet.empty elem.attrs

let compare_nodes ~ignore_whitespace a b =
  let test x y =
    match compare x y with
    | 0 -> ()
    | x -> raise (Compare_result x) in

  let rec find_diff a b =
    test a.tag b.tag;
    let () =
      match AttrSet.compare (set_of_attrs a) (set_of_attrs b) with
      | 0 -> ()
      | x -> raise (Compare_result x) in
    if ignore_whitespace then (
      test (trim a.text_before) (trim b.text_before);
      test (trim a.last_text_inside) (trim b.last_text_inside)
    ) else (
      test a.text_before b.text_before;
      test a.last_text_inside b.last_text_inside
    );
    test (List.length a.child_nodes) (List.length b.child_nodes);
    List.iter2 find_diff a.child_nodes b.child_nodes in

  try find_diff a b; 0
  with Compare_result x -> x

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

  let filter_map ~f node =
    let rec loop = function
      | [] -> []
      | (node::xs) ->
          if fst node.tag = Ns.ns then (
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

  let make doc tag = {
    tag = (Ns.ns, tag);
    attrs = [];
    child_nodes = [];
    text_before = "";
    last_text_inside = "";
    doc;
    pos = (0, 0);
  }

  let make_root tag =
    let doc = {
      source_name = None;
      prefixes = StringMap.singleton "xmlns" Ns.ns
    } in
    make doc tag

  let insert_first tag parent =
    let child = make parent.doc tag in
    parent.child_nodes <- child :: parent.child_nodes;
    child
end
