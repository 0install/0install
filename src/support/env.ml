(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

type t = string XString.Map.t

type name = string

let empty = XString.Map.empty

let parse_binding line =
  match Str.bounded_split_delim XString.re_equals line 2 with
  | [key; value] -> (key, value)
  | _ -> failwith (Printf.sprintf "Invalid environment mapping '%s'" line)

let of_array =
  XString.Map.empty
  |> Array.fold_left @@ fun acc line ->
  let key, value = parse_binding line in
  XString.Map.add key value acc

let put = XString.Map.add
let unset = XString.Map.remove
let get = XString.Map.find_opt

let get_exn k t =
  match get k t with
  | Some v -> v
  | None -> Safe_exn.failf "Environment variable %S not set" k

let to_array t =
  let len = XString.Map.cardinal t in
  let arr = Array.make len "" in
  let item_to_array key value i = (arr.(i) <- key ^ "=" ^ value; i + 1) in
  let check_len = XString.Map.fold item_to_array t 0 in
  assert (len = check_len);
  arr
