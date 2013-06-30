(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing command-line arguments *)

open Common

let starts_with = Utils.starts_with

(* [option names], help text, [arg types]
   'a is the type of the tags, 'b is the type of arg types.
   The callback gets the argument stream (use this for options which take a variable number of arguments)
   and a list of values (one for each declared argument).
   *)
type ('a, 'b) opt = (string list * string * 'b list * (string Stream.t -> string list -> 'a))

type yes_no_maybe = Yes | No | Maybe;;

let string_of_maybe = function
  | Yes -> "yes"
  | No -> "no"
  | Maybe -> "maybe";;

let is_empty stream = None = Stream.peek stream

(* actual option used, tag, list of arguments *)
type 'a option_value = (string * 'a)

type ('a, 'b) argparse_spec = {
  options_spec : ('a, 'b) opt list;

  (** We've just read an argument; should any futher options be treated as arguments? *)
  no_more_options : string list -> bool
}

(* Might want to get rid of this later, but for now we need to throw Fallback_to_Python *)
exception Unknown_option of string

let re_equals = Str.regexp_string "="

let parse_args (spec : ('a,'b) argparse_spec) input_args : ('a option_value list * string list) =
  let options = ref [] in
  let args = ref [] in

  let options_map =
    let map = ref StringMap.empty in
    let add (names, _help, arg_types, fn) =
      List.iter (fun name -> map := StringMap.add name (arg_types, fn) !map) names;
      () in
    List.iter add spec.options_spec;
    !map in

  let lookup_option x =
    try Some (StringMap.find x options_map)
    with Not_found -> None in

  let allow_options = ref true in
  let stream = Stream.of_list input_args in

  let handle_option stream opt =
    match lookup_option opt with
    | None -> raise (Unknown_option opt)
    | Some (arg_types, fn) ->
        let rec get_values = function
          | [] -> []
          | (_::xs) ->
              if is_empty stream then
                raise_safe "Missing argument to option %s" opt
              else
                Stream.next stream :: get_values xs in
        options := (opt, fn stream (get_values arg_types)) :: !options
  in

  let handle_long_option opt =
    match Str.bounded_split_delim re_equals opt 2 with
    | [key; value] ->
        let consumed_value = ref false in
        let value_stream _ =
          if !consumed_value then (
            Some (Stream.next stream)
          ) else (
            consumed_value := true;
            Some value
          ) in
        handle_option (Stream.from value_stream) key;
        if not !consumed_value then
          raise_safe "Option does not take an argument in '%s'" opt
    | _ -> handle_option stream opt in

  let handle_short_option opt =
    let i = ref 1 in
    while !i < String.length opt do
      let opt_stream : string Stream.t =
        if !i + 1 = String.length opt then (
          (* If we're on the last character, any value comes from the next argument *)
          stream
        ) else (
          (* If [handle_option] needs an argument, get it from the rest of this
             option and stop processing after that. *)
          let get_value _ =
            let start = !i + 1 in
            let value = String.sub opt start (String.length opt - start) in
            i := String.length opt;
            Some value in
          Stream.from get_value
        ) in
      handle_option opt_stream @@ "-" ^ (String.make 1 @@ opt.[!i]);
      i := !i + 1
    done

  in
  while not (is_empty stream) do
    match Stream.next stream with
    | "--" when !allow_options -> allow_options := false
    | opt when !allow_options && starts_with opt "--" -> handle_long_option opt
    | opt when !allow_options && starts_with opt "-" -> handle_short_option opt
    | arg ->
        args := arg :: !args;
        if !allow_options && spec.no_more_options !args then allow_options := false
  done;

  (List.rev !options, List.rev !args)
;;

let iter_options (options : 'a option_value list) fn =
  let process (actual_opt, value) =
    try fn value
    with Safe_exception _ as ex -> reraise_with_context ex "... processing option '%s'" actual_opt
  in List.iter process options
;;

(** Run [fn (tag, values)] on each option in turn. [fn] should return [true] if the option was handled.
    Returns a list of unhandled options. If [Safe_exception] is thrown by [fn], we add a context saying which
    option was being handled. *)
let filter_options (options : 'a option_value list) fn =
  let process (actual_opt, value) =
    try not @@ fn value
    with Safe_exception _ as ex -> reraise_with_context ex "... processing option '%s'" actual_opt
  in List.filter process options

(** {2 Handy wrappers for option handlers} *)

let no_arg a _stream = function
  | [] -> a
  | _ -> failwith "Expected no arguments!"

let one_arg fn _stream = function
  | [item] -> fn item
  | _ -> failwith "Expected a single item!"
