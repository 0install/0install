(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Environment variables (generic support code) *)

open Support.Common

type t = string StringMap.t

let empty = StringMap.empty

let of_array arr =
  arr |> Array.fold_left (fun acc line ->
      match Str.bounded_split_delim Support.Utils.re_equals line 2 with
      | [key; value] -> StringMap.add key value acc
      | _ -> failwith (Printf.sprintf "Invalid environment mapping '%s'" line)
    ) StringMap.empty

let put = StringMap.add
let unset = StringMap.remove
let get = StringMap.find

let get_exn k t =
  match get k t with
  | Some v -> v
  | None -> raise_safe "Environment variable %S not set" k

let to_array t =
  let len = StringMap.cardinal t in
  let arr = Array.make len "" in
  let item_to_array key value i = (arr.(i) <- key ^ "=" ^ value; i + 1) in
  let check_len = StringMap.fold item_to_array t 0 in
  assert (len == check_len);
  arr
