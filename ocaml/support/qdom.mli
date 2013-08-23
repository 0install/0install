(** XML processing *)

type document

(** An XML element node (and nearby text). *)
type element = {
  tag: Xmlm.name;
  mutable attrs: Xmlm.attribute list;
  mutable child_nodes: element list;
  mutable text_before: string;        (** The text node immediately before us *)
  mutable last_text_inside: string;   (** The last text node inside us with no following element *)
  doc: document;
  pos: Xmlm.pos;                      (** Location of element in XML *)
};;

(** {2 Parsing} *)

(** @raise Safe_exception if the XML is not well formed. *)
val parse_input : string option -> Xmlm.input -> element

(** @raise Safe_exception if the XML is not well formed. *)
val parse_file : Common.system -> string -> element

(** {2 Helper functions} *)

(** [find fn parent] returns the first child of for which [fn child] is True. *)
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

(** [import_node node doc] makes a copy of [node] for use in [doc]. *)
val import_node : element -> document -> element

(** Get the value of an attribute. *)
val get_attribute_opt : Xmlm.name -> element -> string option

(** Sets the given non-namespaced attribute. *)
val set_attribute : string -> string -> element -> unit

(** Compare two elements and return -1, 0 or 1.
    Owner document, namespace prefixes, row/column source position and attribute order are ignored. *)
val compare_nodes : ignore_whitespace:bool -> element -> element -> int

(** Add or remove whitespace to indent the document nicely. Nodes with simple content
    (e.g. [<name>Bob</name>] do not have their content changed. *)
val reindent : element -> unit

module type NsType = sig val ns : string end

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
      val filter_map : f:(element -> 'a option) -> element -> 'a list

      (** Call [fn] on each child node in our namespace *)
      val iter : f:(element -> unit) -> element -> unit

      (** Call [fn] on each child node in our namespace with local name [tag] *)
      val iter_with_name : f:(element -> unit) -> element -> string -> unit

      (** Get the value of the non-namespaced attribute [attr].
          Throws an exception if [elem] isn't in our namespace. *)
      val tag : element -> string option

      (** @raise Safe_exception if element does not have the expected name and namespace. *)
      val check_tag : string -> element -> unit

      (** @raise Safe_exception if element does not have the expected namespace. *)
      val check_ns : element -> unit

      (** Create a new empty element with no source location. *)
      val make : document -> string -> element

      (** Create a new empty root element with its own document. *)
      val make_root : string -> element

      (** Create a new element as the first child of the given element. *)
      val insert_first : string -> element -> element
    end
