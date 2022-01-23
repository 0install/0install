(** This is a reimplementation of parts of the OCaml 4 Stream API, which was deprecated in 4.14.
    The only API difference is that {!from}'s callback no longer takes a position argument. *)

type 'a t

exception Failure

val of_list : 'a list -> 'a t
val count : 'a t -> int
val empty : 'a t -> unit
val from : (unit -> 'a option) -> 'a t
val next : 'a t -> 'a
val junk : 'a t -> unit
val npeek : int -> 'a t -> 'a list
val peek : 'a t -> 'a option
