(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Escaping and unescaping strings. *)

open General
open Support.Common
module U = Support.Utils

let re_escaped = Str.regexp "#\\|%[0-9a-fA-F][0-9a-fA-F]"
let re_need_escaping = Str.regexp "[^-_.a-zA-Z0-9]"
let re_need_escaping_pretty = Str.regexp (if on_windows
  then "[^-_.a-zA-Z0-9]"
  else "[^-_.a-zA-Z0-9:]")

(* Convert each %20 to a space, etc *)
let unescape uri =
  let fn s =
    let m = Str.matched_string s in
    match m.[0] with
    | '#' -> "/"
    | '%' ->
        let c = Char.chr (int_of_string ("0x" ^ (String.sub m 1 2))) in
        String.make 1 c
    | _ -> assert false
  in Str.global_substitute re_escaped fn uri
;;

(** Legacy escape function. Convert each space to %20, etc *)
let escape uri =
  let fn s =
    let m = Str.matched_string s in
    let c = Char.code m.[0] in         (* docs say ASCII, but should work for UTF-8 too *)
    Printf.sprintf "%%%02x" c
  in Str.global_substitute re_need_escaping fn uri
;;

(** Another legacy escaping function. Convert each space to %20, etc
    : is preserved and / becomes #. This makes for nicer strings than [escape], but has to work
    differently on Windows.
 *)
let pretty uri =
  let fn s =
    let m = Str.matched_string s in
    if m = "/" then "#"
    else
      let c = Char.code m.[0] in         (* docs say ASCII, but should work for UTF-8 too *)
      Printf.sprintf "%%%02x" c
  in Str.global_substitute re_need_escaping_pretty fn uri

(** Escape troublesome characters in [src].
    The result is a valid file leaf name (i.e. does not contain / etc).
    Letters, digits, '-', '.', and characters > 127 are copied unmodified.
    '/' becomes '__'. Other characters become '_code_', where code is the
    lowercase hex value of the character in Unicode. *)
let underscore_escape src =
  let b = Buffer.create (String.length src * 2) in
  for i = 0 to String.length src - 1 do
    match src.[i] with
    | '/' -> Buffer.add_string b "__"
    | '.' when i = 0 ->
        (* Avoid creating hidden files, or specials (. and ..) *)
        Buffer.add_string b "_2e_"
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' -> Buffer.add_char b (src.[i])
    | c when int_of_char c > 127 -> Buffer.add_char b c     (* Top-bit-set chars don't cause any trouble *)
    | c -> Buffer.add_string b @@ Printf.sprintf "_%x_" (int_of_char c)
  done;
  Buffer.contents b

let re_escaped_code = Str.regexp "_\\([0-9a-fA-F]*\\)_"

let ununderscore_escape escaped =
  let ununder_escape m =
    let c = Str.matched_group 1 m in
    if c = "" then "/"
    else String.make 1 (char_of_int @@ int_of_string @@ "0x" ^ c) in

  Str.global_substitute re_escaped_code ununder_escape escaped

(** Convert an interface URI to a list of path components.
    e.g. "http://example.com/foo.xml" becomes ["http", "example.com", "foo.xml"], while
    "/root/feed.xml" becomes ["file", "root__feed.xml"]
    The number of components is determined by the scheme (three for http, two for file).
    Uses [underscore_escape] to escape each component. *)
let escape_interface_uri (uri:iface_uri) : string list =
  let handle_rest rest =
    try
      let i = String.index rest '/' in
      let host = String.sub rest 0 i in
      let path = U.string_tail rest (i + 1) in
      [underscore_escape host; underscore_escape path]
    with Not_found ->
      raise_safe "Invalid URL '%s' (missing third slash)" uri in

  if U.starts_with uri "http://" then
    "http" :: (handle_rest @@ U.string_tail uri 7)
  else if U.starts_with uri "https://" then
    "http" :: (handle_rest @@ U.string_tail uri 8)
  else (
    if not (U.path_is_absolute uri) then
      raise_safe "Invalid interface path '%s' (not absolute)" uri;
    "file" :: [underscore_escape @@U.string_tail uri 1]
  )
