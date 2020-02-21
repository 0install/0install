(* Copyright (C) 2017, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support

type t =
  | Insecure
  | Buggy
  | Developer
  | Testing
  | Stable
  | Packaged
  | Preferred

let of_string ~from_user s =
  let if_from_user l =
    if from_user then l else Safe_exn.failf "Stability '%s' not allowed here" s in
  match s with
  | "insecure" -> Insecure
  | "buggy" -> Buggy
  | "developer" -> Developer
  | "testing" -> Testing
  | "stable" -> Stable
  | "packaged" -> if_from_user Packaged
  | "preferred" -> if_from_user Preferred
  | x -> Safe_exn.failf "Unknown stability level '%s'" x

let to_string = function
  | Insecure -> "insecure"
  | Buggy -> "buggy"
  | Developer -> "developer"
  | Testing -> "testing"
  | Stable -> "stable"
  | Packaged -> "packaged"
  | Preferred -> "preferred"
