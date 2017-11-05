(* Copyright (C) 2017, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

exception Invalid_char

let decode s i =
  match s.[i] with
  | 'A'..'Z' as c -> Char.code c - 65
  | 'a'..'z' as c -> Char.code c - 97 + 26
  | '0'..'9' as c -> Char.code c - 48 + 52
  | '+' -> 62
  | '/' -> 63
  | '=' when i = String.length s - 1 -> raise End_of_file
  | '=' when i = String.length s - 2 && s.[i + 1] = '=' -> raise End_of_file
  | _ -> raise Invalid_char
  | exception _ when i = String.length s -> raise End_of_file

(* Every 6 bits of plain text become 8 bits of encoded data, so
   every 3 bytes (24 bits) of plain text become 4 bytes (32 bits) of output. *)
let str_decode s =
  let buf = Buffer.create (3 * ((String.length s + 3) / 4)) in
  let add c = Buffer.add_char buf (Char.chr c) in
  let rec aux i =
    let s1 = decode s i in
    let s2 = decode s (i + 1) in
    add @@ (s1 lsl 2) lor (s2 lsr 4);
    let s3 = decode s (i + 2) in
    add @@ ((s2 land 0xf) lsl 4) lor (s3 lsr 2);
    let s4 = decode s (i + 3) in
    add @@ ((s3 land 0x3) lsl 6) lor s4;
    aux (i + 4)
  in
  try aux 0
  with End_of_file -> Buffer.contents buf
