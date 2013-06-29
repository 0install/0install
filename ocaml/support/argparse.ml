(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing command-line arguments *)

open Common

let starts_with = Utils.starts_with

type 'a opt_type =
  | NoArg of ('a -> unit)
  | OneArg of ('a -> filepath -> unit)

type 'a opt = (string list * string * 'a opt_type);;

type yes_no_maybe = Yes | No | Maybe;;

let string_of_maybe = function
  | Yes -> "yes"
  | No -> "no"
  | Maybe -> "maybe";;

let is_empty stream = None = Stream.peek stream

type 'a spec = {
  options : 'a opt list;
  arg_handler : bool ref -> string -> unit;
}

(* Might want to get rid of this later, but for now we need to throw Fallback_to_Python *)
exception Unknown_option of string

let re_equals = Str.regexp_string "="

let parse_args (spec : 'a spec) settings args =
  let options_map =
    let map = ref StringMap.empty in
    let add (names, _help, fn) =
      List.iter (fun name -> map := StringMap.add name fn !map) names;
      () in
    List.iter add spec.options;
    !map in

  let lookup_option x =
    try Some (StringMap.find x options_map)
    with Not_found -> None in

  let allow_options = ref true in
  let stream = Stream.of_list args in

  let handle_option stream opt =
    match lookup_option opt with
    | None -> raise (Unknown_option opt)
    | Some (NoArg fn) -> fn settings
    | Some (OneArg fn) ->
        if is_empty stream then
          raise_safe "Missing argument to option %s" opt
        else
          fn settings (Stream.next stream) in

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
    | arg -> spec.arg_handler allow_options arg
  done
;;
