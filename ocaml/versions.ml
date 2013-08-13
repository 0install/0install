(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing version numbers *)

open Support.Common
module U = Support.Utils

type modifier =
  | Pre
  | Rc
  | Dash
  | Post

let re_version_mod = Str.regexp "-[a-z]*"
let re_dot = Str.regexp_string "."

type dotted_int = Int64.t list

type parsed_version =
  (dotted_int * modifier) list

let strip_modifier (version:parsed_version) : parsed_version =
  let dotted = fst (List.hd version) in
  [(dotted, Dash)]

type version_expr = parsed_version -> bool

let parse_mod = function
  | "-pre" -> Pre
  | "-rc" -> Rc
  | "-" -> Dash
  | "-post" -> Post
  | x -> raise_safe "Invalid version modifier '%s'" x

let string_of_mod = function
  | Pre -> "-pre"
  | Rc -> "-rc"
  | Dash -> "-"
  | Post -> "-post"

(* A special version that matches every expression. Used by the solver to provide diagnostics when a solve fails. *)
let dummy : parsed_version = [([Int64.of_int (-1)], Dash)]

(** Convert a version string to an internal representation.
    The parsed format can be compared using the regular comparison operators.
     - Version := DottedList ("-" Mod DottedList?)*
     - DottedList := (Integer ("." Integer)* )
    @raise Safe_exception if the string isn't a valid version
 *)
let parse_version version_string =
  let int64_of_string s =
    try Int64.of_string s
    with Failure _ -> raise_safe "Cannot parse '%s' as a 64-bit integer (in '%s')" s version_string in

  let parse_dotted d =
    let parts = Str.split_delim re_dot d in
    List.map int64_of_string parts in

  let open Str in
  let parts = Str.full_split re_version_mod version_string in

  let rec process = function
    | [Text _; Delim "-"] -> raise_safe "Version ends with a dash: '%s'" version_string
    | Text d :: Delim m :: xs -> (parse_dotted d, parse_mod m) :: process xs
    | [Text d] -> [(parse_dotted d, Dash)]          (* Ends with a number *)
    | Delim _ as d :: xs -> process @@ Text "" :: d :: xs
    | [] -> []
    | Text _ :: Text _ :: _ -> assert false in

  let parsed = process parts in

  if parsed = [] then raise_safe "Empty version string!";

  parsed

let format_version parsed =
  let n_remaining = ref (List.length parsed) in
  let format_seg (d, m) =
    n_remaining := !n_remaining - 1;
    let ms = if !n_remaining = 0 && m = Dash then "" else string_of_mod m in
    String.concat "." (List.map Int64.to_string d) ^ ms in

  String.concat "" (List.map format_seg parsed)

let re_pipe = Str.regexp_string "|"
let re_range = Str.regexp "^\\(.*\\)\\(\\.\\.!?\\)\\(.*\\)$"

let make_range_restriction low high : (parsed_version -> bool) =
  let parse_if_present = function
    | None -> None
    | Some v -> Some (parse_version v) in
  match parse_if_present low, parse_if_present high with
  | None, None -> fun _ -> true
  | Some low, None -> fun v -> v == dummy || low <= v
  | None, Some high -> fun v -> v == dummy || v < high
  | Some low, Some high -> fun v -> v == dummy || (low <= v && v < high)

let parse_range s =
  let s = trim s in
  if Str.string_match re_range s 0 then (
    let low = Str.matched_group 1 s in
    let sep = Str.matched_group 2 s in
    let high = Str.matched_group 3 s in
    let none_if_empty = function
      | "" -> None
      | v -> Some v in

    if high <> "" && sep <> "..!" then (
      raise_safe "End of range must be exclusive (use '..!%s', not '..%s')" high high
    ) else (
      make_range_restriction (none_if_empty low) (none_if_empty high)
    )
  ) else (
    if s <> "" && s.[0] = '!' then (
      (<>) (parse_version (Support.Utils.string_tail s 1))
    ) else (
      (=) (parse_version s)
    )
  )

let parse_expr s =
  try
    let tests = List.map parse_range (Str.split_delim re_pipe s) in
    fun v -> v == dummy || List.exists (fun t -> t v) tests
  with Safe_exception _ as ex -> reraise_with_context ex "... parsing version expression '%s'" s


(* Try to turn a distribution version string into one readable by Zero Install.
   We do this by stripping off anything we can't parse, with some additional heuristics. *)
let rec try_cleanup_distro_version version =
  (* Skip 'epoch' *)
  let version =
    try
      let colon = String.index version ':' in
      U.string_tail version (colon  + 1)
    with Not_found -> String.copy version in

  for i = 0 to String.length version - 1 do
    if version.[i] = '_' then version.[i] <- '-'
  done;

  let (version, suffix) =
    try
      let tilda = String.index version '~' in
      let suffix = U.string_tail version (tilda + 1) in
      let suffix = if U.starts_with suffix "pre" then U.string_tail suffix 3 else suffix in
      (String.sub version 0 tilda, "-pre" ^ (default "" @@ try_cleanup_distro_version suffix))
    with Not_found -> (version, "") in

  let stream = Stream.of_string version in

  let b = Buffer.create (String.length version) in

  let copy n = for _i = 1 to n do Buffer.add_char b (Stream.next stream) done in

  let is_lower = function
    | None -> false
    | Some l -> 'a' <= l && l <= 'z' in

  let is_digit = function
    | None -> false
    | Some d -> '0' <= d && d <= '9' in

  (* Copy the next sequence of "\d+(\.\d+)*" to [b] *)
  let rec accept_dotted_ints () =
    let n = Stream.peek stream in
    if is_digit n then (
      copy 1;
      while is_digit (Stream.peek stream) do copy 1 done;
      match Stream.npeek 2 stream with
      | ['.'; d] when is_digit (Some d) -> copy 1; accept_dotted_ints ()
      | _ -> true
    ) else false
    in

  let accept_mod () =
    match Stream.npeek 5 stream with
    | '-' :: 'p' :: 'r' :: 'e' :: _ -> copy 4; true
    | '-' :: 'p' :: 'o' :: 's' :: 't' :: _ -> copy 5; true
    | '-' :: 'r' :: 'c' :: _ -> copy 3; true
    | '-' :: d :: _ when is_digit (Some d) -> copy 1; true
    | _ -> false in

  let rec accept_zero_install_version () =
    if accept_dotted_ints () then (
      if accept_mod () then (
        accept_zero_install_version ()
      )
    ) in

  (* Skip any leading letter *)
  if is_lower (Stream.peek stream) then Stream.junk stream;
  if accept_dotted_ints () then (
    (* This is for Java-style 6b17 or 7u9 syntax *)
    match Stream.npeek 2 stream with
    | ['.'; 'b'] | ['.'; 'u'] -> copy 1; Stream.junk stream
    | 'b' :: _ | 'u' :: _ -> Stream.junk stream; Buffer.add_char b '.'
    | _  -> ignore @@ accept_mod ()
  );

  accept_zero_install_version ();

  let () = match Stream.npeek 3 stream with
    | ['-'; 'r'; d] when is_digit (Some d) ->
        Stream.junk stream; Stream.junk stream;
        Buffer.add_char b '-';
        ignore @@ accept_dotted_ints ()
    | _ -> () in

  Buffer.add_string b suffix;
  match Buffer.contents b with
  | "" -> None
  | x -> Some x
