(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Secure hashes. *)

type digest_context
external evp_md_ctx_init : string -> digest_context = "ocaml_EVP_MD_CTX_init"
external evp_digest_update : digest_context -> string -> unit = "ocaml_DigestUpdate"
external evp_digest_final_ex : digest_context -> string = "ocaml_DigestFinal_ex"

let hex_chars = "0123456789abcdef"

let create = evp_md_ctx_init
let update = evp_digest_update

(** Return the final digest of [ctx] as an ASCII string. [ctx] cannot be used after this. *)
let digest ctx =
    let raw_digest = evp_digest_final_ex ctx in
    let str_digest = String.create (String.length raw_digest * 2) in
    for i = 0 to String.length raw_digest - 1 do
      str_digest.[i * 2] <- hex_chars.[(Char.code raw_digest.[i] land 0xf0) lsr 4];
      str_digest.[i * 2 + 1] <- hex_chars.[Char.code raw_digest.[i] land 0xf];
    done;
    str_digest
