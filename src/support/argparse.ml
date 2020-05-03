(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing command-line arguments *)

open Common

exception Usage_error of int    (* exit code: e.g. 0 for success, 1 for error *)

type raw_option = (string * string list)

let starts_with = XString.starts_with

class type ['b] option_reader =
  object
    method read : string -> string option -> string Stream.t -> completion:(int option) -> string list
    method get_arg_types : int -> 'b list
  end

class type ['a,'b] option_parser =
  object
    method get_reader : 'b option_reader
    method parse : string list -> 'a
  end

type ('a,'b) opt_spec = (string list * int * string * ('a,'b) option_parser)

let is_empty stream = None = Stream.peek stream

type 'a parsed_options = (string * 'a) list

type ('a,'b) argparse_spec = {
  options_spec : ('a,'b) opt_spec list;

  (* We've just read an argument; should any futher options be treated as arguments? *)
  no_more_options : string list -> bool
}

let re_equals = Str.regexp_string "="

type 'b complete =
  | CompleteNothing               (** There are no possible completions *)
  | CompleteOptionName of string  (** Complete this partial option name *)
  | CompleteOption of (string * 'b option_reader * string list * int)  (* option, reader, values, completion arg *)
  | CompleteArg of int
  | CompleteLiteral of string     (** This is the single possible completion *)

let make_option_map options_spec =
  let map = ref XString.Map.empty in
  let add (names, _nargs, _help, handler) =
    ListLabels.iter names ~f:(fun name ->
      if XString.Map.mem name !map then (
        let reader = handler#get_reader in
        if reader != (XString.Map.find_safe name !map)#get_reader then
          failwith ("Option '" ^ name ^ "' has two different readers")
      ) else (
        map := XString.Map.add name handler !map
      )
    ) in
  List.iter add options_spec;
  !map

let read_args ?(cword) (spec : ('a,'b) argparse_spec) input_args =
  let options = ref [] in
  let args = ref [] in
  let complete = ref CompleteNothing in

  let options_map = make_option_map spec.options_spec in

  let lookup_option x =
    XString.Map.find_opt x options_map |> pipe_some (fun r -> Some r#get_reader) in

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
          Safe_exn.failf "Unknown option '%s'" opt
        )
    | Some handler ->
        let command = match !args with
        | command :: _ -> Some command
        | _ -> None in
        let values = handler#read opt command stream ~completion:carg in
        options := (opt, values) :: !options;
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
          Safe_exn.failf "Option does not take an argument in '%s'" opt
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
      if do_completion && !is_valid && not (XString.Map.mem opt_name options_map) then
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

let parse_options valid_options raw_options =
  let map = make_option_map valid_options in

  let parse_option = function
    | (name, values) ->
        match XString.Map.find_opt name map with
        | None -> Safe_exn.failf "Option '%s' is not valid here" name
        | Some reader ->
            try (name, reader#parse values)
            with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... processing option '%s'" name in

  List.map parse_option raw_options

let iter_options options fn =
  let process (actual_opt, value) =
    try fn value
    with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... processing option '%s'" actual_opt
  in List.iter process options

(** {2 Handy wrappers for option handlers} *)

let no_arg_reader =
  object
    method read _name _command _stream ~completion:_ = []
    method get_arg_types _ = []
  end

class ['a,'b] no_arg (value : 'a) =
  object (_ : ('a,'b) #option_parser)
    method parse = function
      | [] -> value
      | _ -> failwith "Expected no arguments!"
    method get_reader = no_arg_reader
  end

class ['a,'b] one_arg arg_type (fn : string -> 'a) =
  object (_ : ('a,'b) #option_parser)
    method parse = function
      | [item] -> fn item
      | _ -> failwith "Expected a single item!"

    method get_reader =
      object
        method get_arg_types _ = [arg_type]
        method read opt_name _command stream ~completion =
          match Stream.peek stream with
          | None when completion <> None -> [""]
          | None -> Safe_exn.failf "Missing value for option %s" opt_name
          | Some next -> Stream.junk stream; [next]
      end
  end

class ['a,'b] two_arg arg1_type arg2_type (fn : string -> string -> 'a) =
  object (_ : ('a,'b) #option_parser)
    method parse = function
      | [a; b] -> fn a b
      | _ -> failwith "Expected a pair of items!"

    method get_reader =
      object
        method read opt_name _command stream ~completion =
          match Stream.npeek 2 stream with
          | [_; _] as pair -> Stream.junk stream; Stream.junk stream; pair
          | _ when completion = None -> Safe_exn.failf "Missing value for option %s" opt_name
          | [x] -> Stream.junk stream; [x; ""]
          | _ -> [""; ""]

        method get_arg_types _ = [arg1_type; arg2_type]
      end
  end

let pp_options format_type fmt opts =
  let display_options =
    opts |> List.filter_map (fun (names, (nargs:int), help, p) ->
      match help with
      | "" -> None
      | help ->
          let types = p#get_reader#get_arg_types nargs in
          let format_opt name =
            let sep = if not (starts_with name "--") then " " else "=" in
            name ^ match types with
            | [] -> ""
            | [x] -> sep ^ format_type x
            | xs -> sep ^ String.concat " " (List.map format_type xs) in
          let arg_strs = String.concat ", " (List.map format_opt names) in

          Some (arg_strs, help)) in
  let col1_width = 2 + (min 20 @@ List.fold_left (fun w (syn, _help) -> max (String.length syn) w) 0 display_options) in
  let spaces n = String.make n ' ' in
  let pp_items fmt items =
    let need_cut = ref false in
    items |> List.iter (fun (syn, help) ->
      if !need_cut then Format.pp_print_cut fmt ()
      else need_cut := true;
      let padding = col1_width - String.length syn in
      if padding > 0 then
        Format.fprintf fmt "%s%s%s" syn (spaces padding) help
      else
        Format.fprintf fmt "%s@\n%s%s" syn (spaces col1_width) help
    ) in
  Format.fprintf fmt "Options:@,@[<v2>  %a@]" pp_items display_options
