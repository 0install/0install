(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Secure hashes. *)

type digest_context

(** Create a new context from an algorithm name.
 * Supported names are "sha1" and "sha256". *)
val create : string -> digest_context

(** Add bytes to a context. *)
val update : digest_context -> string -> unit

(** Return the final digest of [ctx] as an ASCII string. [ctx] cannot be used after this. *)
val hex_digest : digest_context -> string

(** Return the digest as a base-32-encoded ASCII string (with no padding characters) *)
val b32_digest : digest_context -> string

(** Read until the end of the channel, adding each byte to the digest. *)
val update_from_channel : digest_context -> in_channel -> unit
