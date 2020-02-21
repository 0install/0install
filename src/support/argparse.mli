(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing command-line arguments *)

exception Usage_error of int    (* exit code: e.g. 0 for success, 1 for error *)

(** The option name and its arguments. e.g. ("--wrapper"; ["echo"]) *)
type raw_option = (string * string list)

(** Takes a stream of arguments and takes as many as are needed for the option.
    e.g. [["--version"; "--help"]] takes [["--version"]] and leaves [["--help"]]
    while [["--version"; "1.0"]] takes [["--version"; "1.0"]] and leaves [[]].
  *)
class type ['b] option_reader =
  object
    (** [read opt_name first_arg stream completion].
        Extract as many elements from the stream as this option needs.
        [completion] indicates when we're doing completion (so don't
        raise an error if the arguments are malformed unless this is None).
        When [Some 0], the next item in the stream is being completed, etc.
        *)
    method read :
      string -> string option ->
      string Stream.t -> completion:int option -> string list

    method get_arg_types : int -> 'b list
  end

class type ['a, 'b] option_parser =
  object
    method get_reader : 'b option_reader
    method parse : string list -> 'a
  end

(* [option names], n_args, help text, parser
   'a is the type of the tags, 'b is the type of arg types.
   The parser gets the argument stream (use this for options which take a variable number of arguments)
   and a list of values (one for each declared argument). *)
type ('a, 'b) opt_spec = string list * int * string * ('a, 'b) option_parser

type ('a, 'b) argparse_spec = {
  options_spec : ('a, 'b) opt_spec list;
  no_more_options : string list -> bool;
}

type 'b complete =
  | CompleteNothing               (** There are no possible completions *)
  | CompleteOptionName of string  (** Complete this partial option name *)
  | CompleteOption of (string * 'b option_reader * string list * int)  (* option, reader, values, completion arg *)
  | CompleteArg of int
  | CompleteLiteral of string     (** This is the single possible completion *)

(** [cword] is the index in [input_args] that we are trying to complete, or None if we're not completing. *)
val read_args : ?cword:int -> ('a, 'b) argparse_spec -> string list -> raw_option list * string list * 'b complete

type 'a parsed_options

val parse_options : ('a, 'b) opt_spec list -> raw_option list -> 'a parsed_options

(** Invoke the callback on each option. If it raises [Safe_exn.T], add the name of the option to the error message. *)
val iter_options : 'a parsed_options -> ('a -> unit) -> unit

(** {2 Handy wrappers for option handlers} *)

(** The trivial reader for options which take no arguments. *)
val no_arg_reader : 'b option_reader

(** Always returns a constant value (e.g. --help becomes ShowHelp) . *)
class ['a, 'b] no_arg : 'a -> ['a, 'b] option_parser

class ['a, 'b] one_arg : 'b -> (string -> 'a) -> ['a, 'b] option_parser

class ['a, 'b] two_arg : 'b -> 'b -> (string -> string -> 'a) -> ['a, 'b] option_parser

(** Print out these options in a formatted list. *)
val pp_options : ('b -> string) -> Format.formatter -> ('a, 'b) opt_spec list -> unit
