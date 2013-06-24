(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Escaping and unescaping strings. *)

let re_escaped = Str.regexp "#\\|%[0-9a-fA-F][0-9a-fA-F]"
let re_need_escaping =        Str.regexp "[^-_.a-zA-Z0-9]"

(* Convert each %20 to a space, etc *)
let unescape uri =
  let fn s =
    let m = Str.matched_string s in
    match m.[0] with
    | '#' -> "/"
    | '%' ->
      let c = Char.chr (int_of_string ("0x" ^ (String.sub m 1 3))) in
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
(* TODO - Windows *)
let pretty uri =
  let fn s =
    let m = Str.matched_string s in
    if m = "/" then "#"
    else
      let c = Char.code m.[0] in         (* docs say ASCII, but should work for UTF-8 too *)
      Printf.sprintf "%%%02x" c
  in Str.global_substitute re_need_escaping fn uri
