(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Common

module AttrType =
  struct
    type t = Xmlm.name

    let compare a b = compare a b
  end

module AttrMap =
  struct
    module M = Map.Make(AttrType)

    type t = (string * string) M.t   (* (prefix_hint, value) *)

    let empty = M.empty

    let get name attrs =
      match M.find_opt name attrs with
      | Some (_, value) -> Some value
      | None -> None

    let get_no_ns name attrs =
      get ("", name) attrs

    let add_no_ns name value attrs =
      M.add ("", name) ("", value) attrs

    let add ~prefix name value =
      M.add name (prefix, value)

    let singleton name value =
      M.singleton ("", name) ("", value)

    let remove = M.remove
    let mem = M.mem

    let compare a b =
      M.compare (fun (_, a_value) (_, b_value) -> String.compare a_value b_value) a b

    let add_all overrides attrs =
      M.merge (fun _key old override ->
        match old, override with
        | _, (Some _ as override) -> override
        | (Some _ as old), None -> old
        | None, None -> None
      ) attrs overrides

    let iter_values fn attrs =
      M.iter (fun tag (_prefix, value) -> fn tag value) attrs

    let map fn attrs =
      M.map (fun (hint, value) -> (hint, fn value)) attrs
  end

(* Used in diagnostic messages to show the source of an element. *)
type source_hint =
  | Pos of (Xmlm.pos * filepath option)  (* A location in our document *)
  | GeneratedFrom of element  (* Another element (which was used to generate this one) *)
  | Generated                 (* No further information *)

(** An XML element node, including nearby text. *)
and element = {
  prefix_hint : string;
  tag: Xmlm.name;
  attrs: AttrMap.t;
  child_nodes: element list;
  text_before: string;        (** The text node immediately before us *)
  last_text_inside: string;   (** The last text node inside us with no following element *)
  source_hint: source_hint;
}

let parse_input source_name i = try (
  (* When we see an xmlns attribute, store the prefix here as a hint.
   * Each time we store a qname, we include a hint (which may or may not
   * be the one it had originally). These are used during output to
   * give sensible prefixes, if possible.
   *)
  let prefix_hints = Hashtbl.create 2 in

  let get_hint ns =
    try Hashtbl.find prefix_hints ns
    with Not_found -> Safe_exn.failf "BUG: missing prefix '%s'" ns in

  (* This is a dummy mapping for non-namespaced documents. It shouldn't be used, because the
   * root must be non-namespaced too in that case, and therefore "" will be the default namespace
   * anyway, and not need a prefix. *)
  Hashtbl.add prefix_hints "" "nons";
  Hashtbl.add prefix_hints Xmlm.ns_xml "xml";

  let extract_namespaces attrs =
    let non_ns_attrs =
      attrs |> List.filter (fun ((ns, name), value) ->
        if ns = Xmlm.ns_xmlns then (
          if name = "xmlns" then
            Hashtbl.replace prefix_hints value ""
          else
            Hashtbl.replace prefix_hints value name;
          false
        ) else (
          true
        )
      ) in
    (* Now we have all the prefixes defined, attach them to the remaining attributes *)
    let map = ref AttrMap.empty in
    non_ns_attrs |> List.iter (fun ((ns, name), value) ->
      let prefix = if ns = "" then ns else get_hint ns in
      map := !map |> AttrMap.add ~prefix (ns, name) value
    );
    !map in

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
          let attrs = extract_namespaces attrs in
          let child_nodes, trailing_text = parse_nodes i [] "" in
          let new_node = {
            prefix_hint = get_hint (fst tag);
            tag;
            attrs;
            child_nodes = List.rev child_nodes;
            text_before = prev_text;
            last_text_inside = trailing_text;
            source_hint = Pos (pos, source_name);
          } in parse_nodes i (new_node :: prev_siblings) ""
        )
  in

  match parse_nodes i [] "" with
  | [root], "" -> root
  | _ -> failwith("Expected single root node in XML")
) with Xmlm.Error ((line, col), err) ->
  Safe_exn.failf "[%d:%d] %s" line col (Xmlm.error_message err)

let parse_file (system:#filesystem) ?name path =
  try path |> system#with_open_in [Open_rdonly; Open_binary] (fun ch ->
    parse_input (Some (name |> default path)) (Xmlm.make_input (`Channel ch))
  )
  with
  | Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... parsing XML document %s" path
  | Sys_error msg -> Safe_exn.failf "Error parsing XML document '%s': %s" path msg

(** Helper functions. *)

let find pred node =
  List.find_opt pred node.child_nodes

let rec show_with_loc elem =
  match elem.source_hint with
  | GeneratedFrom source -> show_with_loc source
  | Generated | Pos (_, None) ->
      let (_ns, name) = elem.tag in
      Printf.sprintf "<%s> (generated)" name
  | Pos ((line, col), Some path) ->
      let (_ns, name) = elem.tag in
      Printf.sprintf "<%s> at %s:%d:%d" name path line col

module type NS = sig
  val ns : string
  val prefix_hint : string
end

module type NS_QUERY = sig
  val get_attribute : string -> element -> string
  val get_attribute_opt : string -> element -> string option
  val fold_left : ?name:string -> init:'a -> ('a -> element -> 'a) -> element -> 'a
  val map : ?name:string -> (element -> 'a) -> element -> 'a list
  val filter_map : (element -> 'a option) -> element -> 'a list
  val iter : ?name:string -> (element -> unit) -> element -> unit
  val tag : element -> string option
  val check_tag : string -> element -> unit
  val check_ns : element -> unit
  val make : ?source_hint:element -> ?attrs:AttrMap.t -> ?child_nodes:element list -> string -> element
end

let raise_elem fmt =
  let do_raise s elem : 'b =
    Safe_exn.failf "%s %s" s @@ show_with_loc elem
  in Printf.ksprintf do_raise fmt

let log_elem level =
  let do_log s elem =
    Logging.log level "%s %s" s (show_with_loc elem)
  in Printf.ksprintf do_log

let pp_with_loc f elem =
  Format.pp_print_string f (show_with_loc elem)

let simple_content element =
  if element.child_nodes = [] then
    element.last_text_inside
  else
    raise_elem "Non-text child nodes not permitted inside" element

(* Walk the document and choose some prefix bindings from the hints.
 * Every namespace will get exactly one (unique) prefix.
 * The default namespace will be the namespace of the root element and will get prefix ""
 * (unless some attribute requires the use of an explicit prefix). *)
let choose_prefixes root =
  let default_ns = fst root.tag in

  let prefixes = ref XString.Set.empty in
  let prefix_of_ns = Hashtbl.create 2 in
  let add_hint ns prefix_hint =
    if ns = Xmlm.ns_xml then ()     (* Don't need to declare the built-in namespace *)
    else if not (Hashtbl.mem prefix_of_ns ns) then (
      (* Haven't seen this namespace before. Choose a unique prefix for it, based on the hint. *)
      let p = ref (if prefix_hint = "" then "ns" else prefix_hint) in
      let i = ref 0 in
      while XString.Set.mem !p !prefixes do
        i := !i + 1;
        p := prefix_hint ^ (string_of_int !i)
      done;
      let p = !p in
      Hashtbl.add prefix_of_ns ns p;
      prefixes := !prefixes |> XString.Set.add p
    ) in
  let rec collect_hints elem =
    let ns = fst elem.tag in
    if ns <> default_ns then add_hint ns elem.prefix_hint;  (* (we ensure default_ns is bound at the end) *)
    elem.attrs |> AttrMap.M.iter (fun (ns, _) (prefix_hint, _) ->
      if ns <> "" then add_hint ns prefix_hint
    );
    elem.child_nodes |> List.iter collect_hints in
  collect_hints root;
  (* If any attribute is in default_ns, we'll have defined a prefix for it.
   * If not, make default_ns the default (this is the common case). *)
  if default_ns <> "" && not (Hashtbl.mem prefix_of_ns default_ns) then
    Hashtbl.add prefix_of_ns default_ns "";
  prefix_of_ns

let output o root =
  let prefix_of_ns = choose_prefixes root in

  let root_attrs = ref root.attrs in
  prefix_of_ns |> Hashtbl.iter (fun ns prefix ->
    let prefix = if prefix = "" then "xmlns" else prefix in
    root_attrs := !root_attrs |> AttrMap.add ~prefix:"" (Xmlm.ns_xmlns, prefix) ns (* (prefix "" is unused) *)
  );
    
  Xmlm.output o @@ `Dtd None;
  let rec output_node node =
    if node.text_before <> "" then Xmlm.output o @@ `Data node.text_before;
    Xmlm.output o @@ `El_start (node.tag, node.attrs |> AttrMap.M.bindings |> List.map (fun (k, (_, v)) -> (k, v)));
    List.iter output_node node.child_nodes;
    if node.last_text_inside <> "" then Xmlm.output o @@ `Data node.last_text_inside;
    Xmlm.output o @@ `El_end in
  output_node {root with attrs = !root_attrs}

let to_utf8 elem =
  let buf = Buffer.create 1000 in
  let out = Xmlm.make_output @@ `Buffer buf in
  output out elem;
  Buffer.contents buf

let reindent root =
  let rec process indent node = {node with
    text_before = indent ^ String.trim node.text_before;
    child_nodes = List.map (process @@ indent ^ "  ") node.child_nodes;
    last_text_inside =
      if node.child_nodes <> [] then String.trim node.last_text_inside ^ indent
      else node.last_text_inside;
    } in
  process "\n" {root with text_before = ""}

exception Compare_result of int

let compare_nodes ~ignore_whitespace a b =
  let test x y =
    match compare x y with
    | 0 -> ()
    | x -> raise (Compare_result x) in

  let rec find_diff a b =
    test a.tag b.tag;
    let () =
      match AttrMap.compare a.attrs b.attrs with
      | 0 -> ()
      | x -> raise (Compare_result x) in
    if ignore_whitespace then (
      test (String.trim a.text_before) (String.trim b.text_before);
      test (String.trim a.last_text_inside) (String.trim b.last_text_inside)
    ) else (
      test a.text_before b.text_before;
      test a.last_text_inside b.last_text_inside
    );
    test (List.length a.child_nodes) (List.length b.child_nodes);
    List.iter2 find_diff a.child_nodes b.child_nodes in

  try find_diff a b; 0
  with Compare_result x -> x

module NsQuery (Ns : NS) = struct
  (** Return the localName part of this element's tag.
      Throws an exception if it's in the wrong namespace. *)
  let tag elem =
    let (elem_ns, name) = elem.tag in
    if elem_ns = Ns.ns then Some name
    else None

  let map ?name f elem =
    let rec loop = function
      | [] -> []
      | (elem::xs) ->
          let (ns, elem_name) = elem.tag in
          if ns = Ns.ns && (name = None || name = Some elem_name)
          then f elem :: loop xs
          else loop xs in
    loop elem.child_nodes

  let filter_map fn node =
    let rec loop = function
      | [] -> []
      | (node::xs) ->
          if fst node.tag = Ns.ns then (
            match fn node with
            | None -> loop xs
            | Some result -> result :: loop xs
          ) else loop xs in
    loop node.child_nodes

  let check_ns elem =
    let (ns, _) = elem.tag in
    if ns = Ns.ns then ()
    else raise_elem "Element not in namespace %s:" Ns.ns elem

  let get_attribute attr elem =
    check_ns elem;
    AttrMap.get_no_ns attr elem.attrs |? lazy (raise_elem "Missing attribute '%s' on" attr elem)

  let get_attribute_opt attr elem =
    check_ns elem;
    AttrMap.get_no_ns attr elem.attrs

  let iter ?name fn node =
    let fn2 elem =
      let (ns, elem_name) = elem.tag in
      if ns = Ns.ns && (name = None || name = Some elem_name) then fn elem else ()
    in List.iter fn2 node.child_nodes

  let fold_left ?name ~init fn node =
    let fn2 m elem =
      let (ns, elem_name) = elem.tag in
      if ns = Ns.ns && (name = None || name = Some elem_name) then fn m elem else m in
    List.fold_left fn2 init node.child_nodes

  let check_tag expected elem =
    let (ns, name) = elem.tag in
    if ns <> Ns.ns then raise_elem "Element not in namespace %s:" Ns.ns elem
    else if name <> expected then raise_elem "Expected <%s> but found " expected elem
    else ()

  let make ?source_hint ?(attrs=AttrMap.empty) ?(child_nodes=[]) tag = {
    prefix_hint = Ns.prefix_hint;
    tag = (Ns.ns, tag);
    attrs;
    child_nodes;
    text_before = "";
    last_text_inside = "";
    source_hint = match source_hint with
    | None -> Generated
    | Some elem -> GeneratedFrom elem
  }
end

module Empty = NsQuery(
  struct
    let ns = ""
    let prefix_hint = ""
  end
)
