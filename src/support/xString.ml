(* Copyright (C) 2018, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

let re_dash = Str.regexp_string "-"
let re_slash = Str.regexp_string "/"
let re_space = Str.regexp_string " "
let re_tab = Str.regexp_string "\t"
let re_colon = Str.regexp_string ":"
let re_equals = Str.regexp_string "="
let re_semicolon = Str.regexp_string ";"

let starts_with str prefix =
  let ls = String.length str in
  let lp = String.length prefix in
  if lp > ls then false else
    let rec loop i =
      if i = lp then true
      else if str.[i] <> prefix.[i] then false
      else loop (i + 1)
    in loop 0

let ends_with str suffix =
  let ls = String.length str in
  let lp = String.length suffix in
  if lp > ls then false else
    let offset = ls - lp in
    let rec loop i =
      if i = lp then true
      else if str.[i + offset] <> suffix.[i] then false
      else loop (i + 1)
    in loop 0

let tail s i =
  let len = String.length s in
  if i > len then failwith ("String '" ^ s ^ "' too short to split at " ^ (string_of_int i))
  else String.sub s i (len - i)

let to_int_safe s =
  try int_of_string s
  with Failure msg -> Safe_exn.failf "Invalid integer '%s' (%s)" s msg

let split_pair re str =
  match Str.bounded_split_delim re str 2 with
  | [key; value] -> Some (key, value)
  | _ -> None

let split_pair_safe re str =
  match split_pair re str with
  | Some p -> p
  | None -> Safe_exn.failf "Not a pair '%s'" str

module Map = struct
  include Map.Make(String)
  let find_safe key map = try find key map with Not_found -> Safe_exn.failf "BUG: Key '%s' not found in XString.Map!" key
  let map_bindings fn map = fold (fun key value acc -> fn key value :: acc) map []
end

module Set = Set.Make(String)
