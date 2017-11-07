(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Secure hashes. *)

open Common

class type digest_context =
  object
    method update : string -> unit

    (** Return the final digest as an ASCII string. The context cannot be used after this. *)
    method to_hex : string

    (** Return the final digest as a binary string. The context cannot be used after this. *)
    method to_bin : string
  end

#ifdef HAVE_SHA

(* Implementation using the "sha" package *)

module type DIGEST =
  sig
    type ctx
    type t
    val init: unit -> ctx
    val update_string : ctx -> string -> unit
    val finalize : ctx -> t
    val to_bin : t -> string
    val to_hex : t -> string
  end

let make_context (module D : DIGEST) =
  let ctx = D.init () in
  object
    method update data = D.update_string ctx data
    method to_bin = D.finalize ctx |> D.to_bin
    method to_hex = D.finalize ctx |> D.to_hex
  end

let create = function
  | "sha1" -> make_context (module Sha1)
  | "sha256" -> make_context (module Sha256)
  | x -> raise_safe "Unknown digest type '%s'" x

#else

(* Implementation using openssl *)

type evp_context
external evp_md_ctx_init : string -> evp_context = "ocaml_EVP_MD_CTX_init"
external evp_digest_update : evp_context -> string -> unit = "ocaml_DigestUpdate"
external evp_digest_final_ex : evp_context -> string = "ocaml_DigestFinal_ex"

let hex_chars = "0123456789abcdef"

let create alg =
  let ctx = evp_md_ctx_init alg in
  object
    method update = evp_digest_update ctx
    method to_bin = evp_digest_final_ex ctx
    method to_hex =
      let raw_digest = evp_digest_final_ex ctx in
      let str_digest = Bytes.create (String.length raw_digest * 2) in
      for i = 0 to String.length raw_digest - 1 do
        Bytes.set str_digest (i * 2) hex_chars.[(Char.code raw_digest.[i] land 0xf0) lsr 4];
        Bytes.set str_digest (i * 2 + 1) hex_chars.[Char.code raw_digest.[i] land 0xf];
      done;
      Bytes.to_string str_digest
  end

#endif

let hex_digest ctx = ctx#to_hex
let update ctx = ctx#update

let base32_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

(** Return the digest as a base-32-encoded ASCII string (with no padding characters) *)
let b32_digest ctx =
  let raw_digest = ctx#to_bin in
  let str_digest = Bytes.create ((String.length raw_digest * 8 + 4) / 5) in
  let in_byte = ref 0 in
  let in_bit = ref 3 in
  for i = 0 to Bytes.length str_digest - 1 do
    (* Read next five bits from raw_digest *)
    let vl =
      if !in_byte = String.length raw_digest then 0 else
      Char.code raw_digest.[!in_byte] lsr !in_bit in
    let vh =
      if !in_bit > 3 then (
        Char.code raw_digest.[!in_byte - 1] lsl (8 - !in_bit)
      ) else 0 in

    Bytes.set str_digest i (base32_chars.[(vl lor vh) land 31]);
    if !in_bit >= 5 then
      in_bit := !in_bit - 5
    else (
      in_bit := !in_bit + 3;
      incr in_byte
    )
  done;
  Bytes.unsafe_to_string str_digest

(** Read until the end of the channel, adding each byte to the digest. *)
let update_from_channel ctx ch =
  let buf = Bytes.create 4096 in
  let rec read () =
    match input ch buf 0 (Bytes.length buf) with
    | 0 -> ()
    | n ->
        let data = Bytes.sub buf 0 n |> Bytes.unsafe_to_string in
        ctx#update data; read () in
  read ()
