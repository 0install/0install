(** XML processing *)

type source_hint

module AttrType : sig type t = Xmlm.name val compare : 'a -> 'a -> int end
module AttrMap :
  sig
    (** Maps Xmlm.names to (prefix-hint, value) pairs *)
    type t

    val empty : t

    (** Add a binding with a namespace and suggested prefix. *)
    val add : prefix:string -> Xmlm.name -> string -> t -> t

    (** Add a binding with no namespace (and, therefore, no prefix) *)
    val add_no_ns : string -> string -> t -> t

    (** Convenience function to create a map with a single non-namespaced attribute. *)
    val singleton : string -> string -> t

    (** Get the value of this (namespaced) attribute, as an option. *)
    val get : Xmlm.name -> t -> string option

    (** Simple wrapper for [get] for non-namespaced attributes. *)
    val get_no_ns : string -> t -> string option

    val remove : Xmlm.name -> t -> t

    (** Compare maps, ignoring prefix hints. *)
    val compare : t -> t -> int

    val mem : Xmlm.name -> t -> bool

    (** [add_all overrides old_attrs] returns a map with all the bindings of
     * [overrides] plus all non-conflicting bindings from [old_attrs]. *)
    val add_all : t -> t -> t

    (** Iterate over the values (ignoring the prefix hints) *)
    val iter_values : (Xmlm.name -> string -> unit) -> t -> unit

    (** Map attribute values. *)
    val map : (string -> string) -> t -> t
  end

(** An XML element node (and nearby text). *)
type element = {
  prefix_hint : string;               (* Suggested prefix when serialising this element *)
  tag: Xmlm.name;
  attrs: AttrMap.t;
  child_nodes: element list;
  text_before: string;                (** The text node immediately before us *)
  last_text_inside: string;           (** The last text node inside us with no following element *)
  source_hint: source_hint;           (** Location to report in error messages *)
}

(** {2 Parsing} *)

(** @raise Safe_exn.T if the XML is not well formed. *)
val parse_input : string option -> Xmlm.input -> element

(** Load XML from a file.
 * @param name: optional name to report in location messages (if missing, uses file name)
 * @raise Safe_exn.T if the XML is not well formed. *)
val parse_file : #Common.filesystem -> ?name:string -> string -> element

(** {2 Helper functions} *)

(** [find fn parent] returns the first child of [parent] for which [fn child] is True. *)
val find : (element -> bool) -> element -> element option

(** Format a string identifying this element for use in error messages. Includes the source location, if known. *)
val pp_with_loc : Format.formatter -> element -> unit

(** [raise_elem "Problem with" elem] raises a [Safe_exn.T] with the message "Problem with <element> at ..." *)
val raise_elem : ('a, unit, string, element -> 'b) format4 -> 'a

(** Like [raise_elem], but writing a log record rather than raising an exception. *)
val log_elem : Logging.level -> ('a, unit, string, element -> unit) format4 -> 'a

(** Returns the text content of this element.
    @raise Safe_exn.T if it contains any child nodes. *)
val simple_content : element -> string

(** Write out a (sub)tree.
    e.g. [output (Xmlm.make_output @@ `Channel stdout) root] *)
val output : Xmlm.output -> element -> unit

(** Write a (sub)tree to a string. *)
val to_utf8 : element -> string

(** Compare two elements and return -1, 0 or 1.
    Namespace prefixes, row/column source position and attribute order are ignored. *)
val compare_nodes : ignore_whitespace:bool -> element -> element -> int

(** Add or remove whitespace to indent the document nicely. Nodes with simple content
    (e.g. [<name>Bob</name>] do not have their content changed. *)
val reindent : element -> element

module type NS = sig
  val ns : string
  val prefix_hint : string      (* A suggested namespace prefix (for serialisation) *)
end

module type NS_QUERY = sig
  (** Get the value of the non-namespaced attribute [attr].
      Throws an exception if [elem] isn't in our namespace. *)
  val get_attribute : string -> element -> string

  val get_attribute_opt : string -> element -> string option

  val fold_left : ?name:string -> init:'a -> ('a -> element -> 'a) -> element -> 'a

  (** Apply [fn] to each child node in our namespace with local name [name] *)
  val map : ?name:string -> (element -> 'a) -> element -> 'a list

  (** Apply [fn] to each child node in our namespace *)
  val filter_map : (element -> 'a option) -> element -> 'a list

  (** Call [fn] on each child node in our namespace (with name [name]) *)
  val iter : ?name:string -> (element -> unit) -> element -> unit

  (** Get the local name of this element, if it's in our namespace. *)
  val tag : element -> string option

  (** @raise Safe_exn.T if element does not have the expected name and namespace. *)
  val check_tag : string -> element -> unit

  (** @raise Safe_exn.T if element does not have the expected namespace. *)
  val check_ns : element -> unit

  (** Create a new element in our namespace.
   * @param source_hint will be used in error messages *)
  val make : ?source_hint:element -> ?attrs:AttrMap.t -> ?child_nodes:element list -> string -> element
end

module NsQuery (N : NS) : NS_QUERY
(** A module for XML operations specialised to namespace [N]. *)

module Empty : NS_QUERY
(** Operations using the empty namespace. *)
