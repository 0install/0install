module LList = struct
  type 'a item = Nil | Cons of 'a * 'a t
  and 'a t = 'a item Lazy.t

  let rec of_list = function
    | [] -> lazy Nil
    | x :: xs -> lazy (Cons (x, of_list xs))

  let rec from fn =
    lazy (
      match fn () with
      | None -> Nil
      | Some x -> Cons (x, from fn)
    )
end

type 'a t = {
  mutable next : 'a LList.t;
  mutable count : int;
}

exception Failure

let of_lazy x = { next = x; count = 0 }

let of_list x = of_lazy (LList.of_list x)

let count t = t.count

let empty t =
  match t.next with
  | lazy Nil -> ()
  | _ -> raise Failure

let from fn = of_lazy (LList.from fn)

let next t =
  match Lazy.force t.next with
  | Nil -> raise Failure
  | Cons (x, next) ->
    t.next <- next;
    t.count <- t.count + 1;
    x

let junk t = ignore (next t)

let npeek n t =
  let rec aux (next : _ LList.t) = function
    | 0 -> []
    | i ->
      match Lazy.force next with
      | Nil -> []
      | Cons (x, next) ->
        x :: aux next (i - 1)
  in
  aux t.next n

let peek t =
  match Lazy.force t.next with
  | Nil -> None
  | Cons (x, _) -> Some x
