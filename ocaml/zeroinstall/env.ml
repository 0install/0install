(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Environment variables (generic support code) *)

open Support.Common

type t = (varname, string) Hashtbl.t

let create arr =
  let env = Hashtbl.create 1000 in

  arr |> Array.iter (fun line ->
    match Str.bounded_split_delim Support.Utils.re_equals line 2 with
    | [key; value] -> Hashtbl.replace env key value
    | _ -> failwith (Printf.sprintf "Invalid environment mapping '%s'" line)
  );

  env

let put = Hashtbl.replace
let unset = Hashtbl.remove

let get_exn env name =
  try Hashtbl.find env name
  with Not_found -> raise_safe "Environment variable '%s' not set" name

let get env name =
  try Some (Hashtbl.find env name)
  with Not_found -> None

let to_array env =
  let len = Hashtbl.length env in
  let arr = Array.make len "" in
  let item_to_array key value i = (arr.(i) <- key ^ "=" ^ value; i + 1) in
  let check_len = Hashtbl.fold item_to_array env 0 in
  assert (len == check_len);
  arr
