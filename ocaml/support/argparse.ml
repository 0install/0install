(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing command-line arguments *)

open Common

let starts_with = Utils.starts_with

class type ['a,'b] option_parser =
  object
    (** [read opt_name first_arg stream completion].
        Extract as many elements from the stream as this option needs.
        [completion] indicates when we're doing completion (so don't
        raise an error if the arguments are malformed unless this is None).
        When [Some 0], the next item in the stream is being completed, etc.
        *)
    method read : string -> string option -> string Stream.t -> completion:(int option) -> string list

    method parse : string list -> 'a

    method get_arg_types : string list -> 'b list
  end

(* [option names], help text, [arg types]
   'a is the type of the tags, 'b is the type of arg types.
   The callback gets the argument stream (use this for options which take a variable number of arguments)
   and a list of values (one for each declared argument).
   *)
type ('a,'b) opt = (string list * string * ('a,'b) option_parser)

let is_empty stream = None = Stream.peek stream

(* actual option used, tag, list of arguments *)
type 'a option_value = (string * 'a)

type ('a,'b) argparse_spec = {
  options_spec : ('a,'b) opt list;

  (** We've just read an argument; should any futher options be treated as arguments? *)
  no_more_options : string list -> bool
}

let re_equals = Str.regexp_string "="

type ('a,'b) complete =
  | CompleteNothing               (** There are no possible completions *)
  | CompleteOptionName of string  (** Complete this partial option name *)
  | CompleteOption of (string * ('a,'b) option_parser * string list * int)  (* option, handler, values, completion arg *)
  | CompleteArg of int
  | CompleteLiteral of string     (** This is the single possible completion *)

(** [cword] is the index in [input_args] that we are trying to complete, or None if we're not completing. *)
let read_args ?(cword) (spec : ('a,'b) argparse_spec) input_args =
  let options = ref [] in
  let args = ref [] in
  let complete = ref CompleteNothing in

  let options_map =
    let map = ref StringMap.empty in
    let add (names, _help, handler) =
      ListLabels.iter names ~f:(fun name ->
        if StringMap.mem name !map then (
          if handler != StringMap.find name !map then
            failwith ("Option '" ^ name ^ "' has two different handlers")
        ) else (
          map := StringMap.add name handler !map
        )
      ) in
    List.iter add spec.options_spec;
    !map in

  let lookup_option x =
    try Some (StringMap.find x options_map)
    with Not_found -> None in

  let allow_options = ref true in
  let stream = Stream.of_list input_args in

  (* 0 if the next item we will read is the completion word, etc.
     None if we're not doing completion. *)
  let args_to_cword () =
    match cword with
    | None -> None
    | Some i -> Some (i - Stream.count stream) in

  (* Read from [stream] all the values needed by option [opt] and add to [options].
     [carg] is the argument to complete, if in range. -1 to complete the option itself. *)
  let handle_option stream opt ~carg =
    match lookup_option opt with
    | None ->
        if carg = Some (-1) then (
          (* We are completing this option *)
          complete := CompleteOptionName opt
        ) else if cword <> None then (
          (* We are completing elsewhere; just skip unknown options *)
          ()
        ) else (
          raise_safe "Unknown option '%s'" opt
        )
    | Some handler ->
        let command = match !args with
        | command :: _ -> Some command
        | _ -> None in
        let values = handler#read opt command stream ~completion:carg in
        options := (opt, handler, values) :: !options;
        match carg with
        | None -> ()
        | Some -1 ->
            (* Even with an exact match, there may be a longer option *)
            complete := CompleteOptionName opt
        | Some carg ->
            if carg >= 0 && carg < List.length values then (
              complete := CompleteOption (opt, handler, values, carg)
            )
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
        (* If the arg being completed contains an "=", we're always completing the value part *)
        let carg = match args_to_cword () with
        | None -> None
        | Some 0 -> Some 1
        | Some _ -> None in
        handle_option (Stream.from value_stream) key ~carg;
        if cword = None && not !consumed_value then
          raise_safe "Option does not take an argument in '%s'" opt
    | _ -> handle_option stream opt ~carg:(args_to_cword ()) in

  let handle_short_option opt =
    let do_completion = args_to_cword () = Some (-1) in
    let is_valid = ref true in
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
      let opt_name = "-" ^ (String.make 1 @@ opt.[!i]) in
      let carg = if do_completion then Some (-1) else None in
      handle_option opt_stream opt_name ~carg;
      i := !i + 1;
      if do_completion && !is_valid && not (StringMap.mem opt_name options_map) then
        is_valid := false;
    done;
    if do_completion then (
      if !is_valid then
        complete := CompleteLiteral opt
      else
        complete := CompleteNothing
    )
  in
  while not (is_empty stream) do
    let completing_this = args_to_cword () = Some 0 in
    match Stream.next stream with
    | "-" when completing_this ->
        complete := CompleteOptionName "--"
    | "--" when !allow_options ->
        if completing_this then
          handle_long_option "--"   (* start of option being completed *)
        else
          allow_options := false    (* end of options marker *)
    | opt when !allow_options && starts_with opt "--" -> handle_long_option opt
    | opt when !allow_options && starts_with opt "-" -> handle_short_option opt
    | arg ->
        if completing_this && !complete = CompleteNothing then (
          complete := CompleteArg (List.length !args);
        );
        args := arg :: !args;
        if !allow_options && spec.no_more_options !args then allow_options := false
  done;

  (List.rev !options, List.rev !args, !complete)
;;

let parse_args (spec : ('a,'b) argparse_spec) input_args : ('a option_value list * string list) =
  let (raw_options, args, complete) = read_args spec input_args in
  assert (complete = CompleteNothing);
  let parse_option (opt, h, vals) = (opt, h#parse vals) in
  let parsed_options = List.map parse_option raw_options in
  (parsed_options, args)
;;

let iter_options (options : 'a option_value list) fn =
  let process (actual_opt, value) =
    try fn value
    with Safe_exception _ as ex -> reraise_with_context ex "... processing option '%s'" actual_opt
  in List.iter process options
;;

(** {2 Handy wrappers for option handlers} *)

class ['a,'b] no_arg (value : 'a) =
  object (_ : ('a,'b) #option_parser)
    method read _name _command _stream ~completion:_ = []
    method parse = function
      | [] -> value
      | _ -> failwith "Expected no arguments!"
    method get_arg_types _ = []
  end

class ['a,'b] one_arg arg_type (fn : string -> 'a) =
  object (_ : ('a,'b) #option_parser)
    method read opt_name _command stream ~completion =
      match Stream.peek stream with
      | None when completion <> None -> [""]
      | None -> raise_safe "Missing value for option %s" opt_name
      | Some next -> Stream.junk stream; [next]

    method parse = function
      | [item] -> fn item
      | _ -> failwith "Expected a single item!"

    method get_arg_types _ = [arg_type]
  end

class ['a,'b] two_arg arg1_type arg2_type (fn : string -> string -> 'a) =
  object (_ : ('a,'b) #option_parser)
    method read opt_name _command stream ~completion =
      match Stream.npeek 2 stream with
      | [_; _] as pair -> Stream.junk stream; Stream.junk stream; pair
      | _ when completion = None -> raise_safe "Missing value for option %s" opt_name
      | [x] -> [x; ""]
      | _ -> [""; ""]

    method parse = function
      | [a; b] -> fn a b
      | _ -> failwith "Expected a pair of items!"

    method get_arg_types _ = [arg1_type; arg2_type]
  end
