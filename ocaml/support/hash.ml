(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Secure hashes. *)

type digest_context
external evp_md_ctx_init : string -> digest_context = "ocaml_EVP_MD_CTX_init"
external evp_digest_update : digest_context -> string -> unit = "ocaml_DigestUpdate"
external evp_digest_final_ex : digest_context -> string = "ocaml_DigestFinal_ex"

let hex_chars = "0123456789abcdef"
let base32_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

let create = evp_md_ctx_init
let update = evp_digest_update

(** Return the final digest of [ctx] as an ASCII string. [ctx] cannot be used after this. *)
let hex_digest ctx =
  let raw_digest = evp_digest_final_ex ctx in
  let str_digest = String.create (String.length raw_digest * 2) in
  for i = 0 to String.length raw_digest - 1 do
    str_digest.[i * 2] <- hex_chars.[(Char.code raw_digest.[i] land 0xf0) lsr 4];
    str_digest.[i * 2 + 1] <- hex_chars.[Char.code raw_digest.[i] land 0xf];
  done;
  str_digest

(** Return the digest as a base-32-encoded ASCII string (with no padding characters) *)
let b32_digest ctx =
  let raw_digest = evp_digest_final_ex ctx in
  let str_digest = String.create ((String.length raw_digest * 8 + 4) / 5) in
  let in_byte = ref 0 in
  let in_bit = ref 3 in
  for i = 0 to String.length str_digest - 1 do
    (* Read next five bits from raw_digest *)
    let vl =
      if !in_byte = String.length raw_digest then 0 else
      Char.code raw_digest.[!in_byte] lsr !in_bit in
    let vh =
      if !in_bit > 3 then (
        Char.code raw_digest.[!in_byte - 1] lsl (8 - !in_bit)
      ) else 0 in

    str_digest.[i] <- base32_chars.[(vl lor vh) land 31];
    if !in_bit >= 5 then
      in_bit := !in_bit - 5
    else (
      in_bit := !in_bit + 3;
      incr in_byte
    )
  done;
  str_digest

(** Read until the end of the channel, adding each byte to the digest. *)
let update_from_channel ctx ch =
  let buf = String.create 4096 in
  let rec read () =
    match input ch buf 0 (String.length buf) with
    | 0 -> ()
    | n -> update ctx (String.sub buf 0 n); read () in
  read ()
