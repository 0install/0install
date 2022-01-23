(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing version numbers *)

open Support
open Support.Common

type modifier =
  | Pre
  | Rc
  | Dash
  | Post

let re_version_mod = Str.regexp "-[a-z]*"
let re_dot = Str.regexp_string "."

type dotted_int = Int64.t list

type t =
  (dotted_int * modifier) list

let strip_modifier (version:t) : t =
  let dotted = fst (List.hd version) in
  [(dotted, Dash)]

type version_expr = t -> bool

let parse_mod = function
  | "-pre" -> Pre
  | "-rc" -> Rc
  | "-" -> Dash
  | "-post" -> Post
  | x -> Safe_exn.failf "Invalid version modifier '%s'" x

let string_of_mod = function
  | Pre -> "-pre"
  | Rc -> "-rc"
  | Dash -> "-"
  | Post -> "-post"

let parse version_string =
  let int64_of_string s =
    try Int64.of_string s
    with Failure _ -> Safe_exn.failf "Cannot parse '%s' as a 64-bit integer (in '%s')" s version_string in

  let parse_dotted d =
    let parts = Str.split_delim re_dot d in
    List.map int64_of_string parts in

  let open Str in
  let parts = Str.full_split re_version_mod version_string in

  let rec process = function
    | [Text _; Delim "-"] -> Safe_exn.failf "Version ends with a dash: '%s'" version_string
    | Text d :: Delim m :: xs -> (parse_dotted d, parse_mod m) :: process xs
    | [Text d] -> [(parse_dotted d, Dash)]          (* Ends with a number *)
    | Delim _ as d :: xs -> process @@ Text "" :: d :: xs
    | [] -> []
    | Text _ :: Text _ :: _ -> assert false in

  let parsed = process parts in

  if parsed = [] then Safe_exn.failf "Empty version string!";

  parsed

let to_string parsed =
  let n_remaining = ref (List.length parsed) in
  let format_seg (d, m) =
    n_remaining := !n_remaining - 1;
    let ms = if !n_remaining = 0 && m = Dash then "" else string_of_mod m in
    String.concat "." (List.map Int64.to_string d) ^ ms in

  String.concat "" (List.map format_seg parsed)

let pp f v = Format.pp_print_string f (to_string v)

let re_pipe = Str.regexp_string "|"
let re_range = Str.regexp "^\\(.*\\)\\(\\.\\.!?\\)\\(.*\\)$"

let make_range_restriction low high : (t -> bool) =
  let parse_if_present = function
    | None -> None
    | Some v -> Some (parse v) in
  match parse_if_present low, parse_if_present high with
  | None, None -> fun _ -> true
  | Some low, None -> fun v -> low <= v
  | None, Some high -> fun v -> v < high
  | Some low, Some high -> fun v -> (low <= v && v < high)

let parse_range s =
  let s = String.trim s in
  if Str.string_match re_range s 0 then (
    let low = Str.matched_group 1 s in
    let sep = Str.matched_group 2 s in
    let high = Str.matched_group 3 s in
    let none_if_empty = function
      | "" -> None
      | v -> Some v in

    if high <> "" && sep <> "..!" then (
      Safe_exn.failf "End of range must be exclusive (use '..!%s', not '..%s')" high high
    ) else (
      make_range_restriction (none_if_empty low) (none_if_empty high)
    )
  ) else (
    if s <> "" && s.[0] = '!' then (
      (<>) (parse (Support.XString.tail s 1))
    ) else (
      (=) (parse s)
    )
  )

let parse_expr s =
  try
    let tests = List.map parse_range (Str.split_delim re_pipe s) in
    fun v -> List.exists (fun t -> t v) tests
  with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... parsing version expression '%s'" s

(** Any distribution-provided version number is capped to this.
 * Prevents them wrapping around (very large numbers are usually hashes anyway).
 * We use a special-looking decimal number to make it more obvious what has happened. *)
let version_limit = 9999999999999999L

module Stream = struct
  type t = { x : string; mutable pos : int }

  let of_string x = { x; pos = 0 }

  let junk_n t n =
    let i' = t.pos + n in
    assert (n >= 0 && i' <= String.length t.x);
    t.pos <- i'

  let junk t = junk_n t 1

  let peek t =
    if t.pos < String.length t.x then Some (t.x.[t.pos])
    else None

  let npeek n t =
    let n = min n (String.length t.x - t.pos) in
    List.init n (fun i -> t.x.[t.pos + i])
end

let try_cleanup_distro_version version =
  let result' = ref [] in
  let stream = Stream.of_string version in

  let junk n =
    for _i = 1 to n do Stream.junk stream done in

  let accept_digit () =
    match Stream.peek stream with
    | Some ('0' .. '9' as d) -> Stream.junk stream; Some (Char.code d - 48 |> Int64.of_int)
    | _  -> None in

  let rec accept_more_digits v =
    match accept_digit () with
    | None -> v
    | Some _ when v >= version_limit -> accept_more_digits version_limit
    | Some d -> Int64.add (Int64.mul v 10L) d |> accept_more_digits in

  let rec skip_lower () =
    match Stream.peek stream with
    | Some ('a' .. 'z') -> Stream.junk stream; skip_lower ()
    | _ -> () in

  let accept_int () =
    accept_digit ()
    |> pipe_some (fun d -> Some (accept_more_digits d)) in

  let rec accept_dotted_ints () =
    match accept_int () with
    | None -> []
    | Some i ->
        match Stream.npeek 2 stream with
        | ['a' .. 'z'; '0' .. '9'] ->
            (* Java 6b17, etc *)
            Stream.junk stream;
            i :: accept_dotted_ints ()
        | _ ->
            skip_lower ();
            if Stream.peek stream = Some '.' then (
              Stream.junk stream;
              skip_lower ();
              i :: accept_dotted_ints ()
            ) else [i] in

  let accept_mod () =
    match Stream.peek stream with
    | Some '~' -> Stream.junk stream; Pre    (* (Debian) *)
    | Some ('_' | '-') ->
        Stream.junk stream;
        begin match Stream.npeek 4 stream with
        | 'p' :: 'r' :: 'e' :: _ -> junk 3; Pre
        | 'p' :: 'o' :: 's' :: 't' :: _ -> junk 4; Post
        | 'r' :: 'c' :: _ -> junk 2; Rc
        | 'r' :: ('0' .. '9') :: _ -> junk 1; Dash
        | _ -> Dash end
    | _ -> Dash in

  let rec loop () =
    match Stream.peek stream with
    | None ->
        begin match List.rev !result' with
        | [] -> None
        | v -> Some v end
    | Some ':' ->
        (* Skip everything before the 'epoch' *)
        result' := [];
        Stream.junk stream;
        loop ()
    | Some ('0' .. '9') ->
        let ints = accept_dotted_ints () in
        let modifier = accept_mod () in
        result' := (ints, modifier) :: !result';
        loop ()
    | Some _ ->
        Stream.junk stream;
        loop () (* Skip unknown characters *) in
  loop ()
