(* Copyright (C) 2018, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Extra string utilities. *)

val starts_with : string -> string -> bool
(** [starts_with s prefix] is [true] iff [s] starts with [prefix]. *)

val ends_with : string -> string -> bool
(** [ends_with s suffix] is [true] iff [s] ends with [suffix]. *)

val tail : string -> int -> string
(** [tail s n] is [s] without the first [n] chars. Raises an exception if [String.length s < n]. *)

val split_pair : Str.regexp -> string -> (string * string) option
(** [split_pair re s] splits [s] at the left-most occurance of [re] and returns the pair of the
    parts before and after the match. Returns [None] if [re] does not occur in [s]. *)

val split_pair_safe : Str.regexp -> string -> string * string
(** [split_pair_safe] is like [split_pair], but raises [Safe_exn.T] if there is no match. *)

val to_int_safe : string -> int
(** [to_int_safe s] is like [int_of_string], but raises a more helpful [Safe_exn.T] on failure. *)

val re_dash : Str.regexp
val re_slash : Str.regexp
val re_space : Str.regexp
val re_tab : Str.regexp
val re_colon : Str.regexp
val re_equals : Str.regexp
val re_semicolon : Str.regexp

module Map : sig
  include Map.S with type key = string

  val find_safe : string -> 'a t -> 'a
  (** Like [find], but raises [Safe_exn.t] if the key is missing,
      with a message that includes the name of the missing key. *)

  val map_bindings : (string -> 'a -> 'b) -> 'a t -> 'b list
  (** [map_bindings f t] is [List.map f (bindings t)]. *)
end

module Set : Set.S with type elt = string
