(* Copyright (C) 2017, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The stability rating of an implementation. These are set by the author in the upstread feed,
    but can be overridden by users. *)

type t =
  | Insecure
  | Buggy
  | Developer
  | Testing
  | Stable
  | Packaged
  | Preferred

val of_string : from_user:bool -> string -> t
(** The ratings [Packaged] and [Preferred] are only allowed if [from_user] is set. *)

val to_string : t -> string
