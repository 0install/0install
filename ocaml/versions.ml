(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing version numbers *)

open Support.Common

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
