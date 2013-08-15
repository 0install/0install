(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A simple dynamically expanding array. When it gets full, it doubles in size. *)

module type ELEMENT_TYPE =
  sig
    type t
    val undefined : t   (* We need an element to put in the unused elements of the array; it is never used *)
  end

module Make(ElementType:ELEMENT_TYPE) =
  struct
    type elt = ElementType.t

    type t = {
      mutable n : int;
      mutable arr : ElementType.t array;
    }

    let add item da =
      let new_n = da.n + 1 in
      if new_n >= Array.length da.arr then (
        let new_arr = Array.make (new_n * 2) ElementType.undefined in
        Array.blit da.arr 0 new_arr 0 da.n;
        da.arr <- new_arr
      );
      da.arr.(da.n) <- item;
      da.n <- new_n

    let get index da =
      assert (index < da.n);
      da.arr.(index)

    let set index value da =
      assert (index < da.n);
      da.arr.(index) <- value

    let make () = { n = 0; arr = [| |] }

    let for_all fn da =
      let n = da.n in
      let rec loop i =
        if i = n then
          true
        else if fn (da.arr.(i)) then
          loop (i + 1)
        else
          false in
      loop 0

    let find_index fn da =
      let n = da.n in
      let rec loop i =
        if i = n then
          None
        else if fn (da.arr.(i)) then
          Some i
        else
          loop (i + 1) in
      loop 0
  end
