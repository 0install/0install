(** XML processing *)

type source_hint
type attr_value = (string * string)   (* (prefix_hint, value) *)

module AttrType : sig type t = Xmlm.name val compare : 'a -> 'a -> int end
module AttrMap :
  sig
    include Map.S with type key = AttrType.t

    (* Add a binding with no namespace (and, therefore, no prefix) *)
    val add_no_ns : string -> string -> attr_value t -> attr_value t

    (* Get the value of this (namespaced) attribute, as an option. *)
    val get : Xmlm.name -> attr_value t -> string option

    (* Simple wrapper for [get] for non-namespaced attributes. *)
    val get_no_ns : string -> attr_value t -> string option
  end
type attributes = (string * string) AttrMap.t

(** An XML element node (and nearby text). *)
type element = {
  prefix_hint : string;               (* Suggested prefix when serialising this element *)
  tag: Xmlm.name;
  mutable attrs: attributes;
  mutable child_nodes: element list;
  text_before: string;                (** The text node immediately before us *)
  last_text_inside: string;           (** The last text node inside us with no following element *)
  source_hint: source_hint;           (** Location to report in error messages *)
}

(** {2 Parsing} *)

(** @raise Safe_exception if the XML is not well formed. *)
val parse_input : string option -> Xmlm.input -> element

(** @raise Safe_exception if the XML is not well formed. *)
val parse_file : Common.system -> string -> element

(** {2 Helper functions} *)

(** [find fn parent] returns the first child of [parent] for which [fn child] is True. *)
val find : (element -> bool) -> element -> element option

(** Generate a string identifying this element for use in error messages. Includes the source location, if known. *)
val show_with_loc : element -> string

(** [raise_elem "Problem with" elem] raises a [Safe_exception] with the message "Problem with <element> at ..." *)
val raise_elem : ('a, unit, string, element -> 'b) format4 -> 'a

(** Like [raise_elem], but writing a log record rather than raising an exception. *)
val log_elem : Logging.level -> ('a, unit, string, element -> unit) format4 -> 'a

(** Returns the text content of this element.
    @raise Safe_exception if it contains any child nodes. *)
val simple_content : element -> string

(** Write out a (sub)tree.
    e.g. [output (Xmlm.make_output @@ `Channel stdout) root] *)
val output : Xmlm.output -> element -> unit

(** Write a (sub)tree to a string. *)
val to_utf8 : element -> string

(** [prepend_child child parent] makes [child] the first child of [parent]. *)
val prepend_child : element -> element -> unit

(** Sets the given non-namespaced attribute. *)
val set_attribute : string -> string -> element -> unit

(** Sets the given namespaced attribute.
 * A new namespace declaration will be added, by default named [prefix]. If [prefix] is already bound
 * to a different namespace, a new unique prefix is chosen instead. *)
val set_attribute_ns : prefix:string -> Xmlm.name -> string -> element -> unit

(** Compare two elements and return -1, 0 or 1.
    Namespace prefixes, row/column source position and attribute order are ignored. *)
val compare_nodes : ignore_whitespace:bool -> element -> element -> int

(** Add or remove whitespace to indent the document nicely. Nodes with simple content
    (e.g. [<name>Bob</name>] do not have their content changed. *)
val reindent : element -> element

(* Convert a list of (name, value) pairs into a set of (non-namespaced) attributes. *)
val attrs_of_list : (string * string) list -> attributes

val iter_attrs : (Xmlm.name -> string -> unit) -> element -> unit

module type NsType = sig
  val ns : string
  val prefix_hint : string      (* A suggested namespace prefix (for serialisation) *)
end

module NsQuery :
  functor (Ns : NsType) ->
    sig
      (** Get the value of the non-namespaced attribute [attr].
          Throws an exception if [elem] isn't in our namespace. *)
      val get_attribute : string -> element -> string

      val get_attribute_opt : string -> element -> string option

      val fold_left : f:('a -> element -> 'a) -> 'a -> element -> string -> 'a

      (** Apply [fn] to each child node in our namespace with local name [tag] *)
      val map : f:(element -> 'a) -> element -> string -> 'a list

      (** Apply [fn] to each child node in our namespace *)
      val filter_map : (element -> 'a option) -> element -> 'a list

      (** Call [fn] on each child node in our namespace (with name [name]) *)
      val iter : ?name:string -> (element -> unit) -> element -> unit

      (** Get the local name of this element, if it's in our namespace. *)
      val tag : element -> string option

      (** @raise Safe_exception if element does not have the expected name and namespace. *)
      val check_tag : string -> element -> unit

      (** @raise Safe_exception if element does not have the expected namespace. *)
      val check_ns : element -> unit

      (** Create a new element in our namespace.
       * @param source_hint will be used in error messages *)
      val make : ?source_hint:element -> ?attrs:attributes -> string -> element

      (** Create a new element as the first child of the given element. *)
      val insert_first : ?source_hint:element -> string -> element -> element
    end
