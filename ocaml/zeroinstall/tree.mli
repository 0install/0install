(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Getting the dependency tree from a selections document. *)

module Make (Model : Sigs.SELECTIONS) : sig
  type node =
    Model.Role.t * [
      | `Problem
      | `Selected of Model.impl * node list
    ]

  val as_tree : Model.t -> node
end

val print : General.config -> Format.formatter -> Selections.t -> unit
