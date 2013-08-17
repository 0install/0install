(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Environment variables (generic support code) *)

open Support.Common

type env = (string, string) Hashtbl.t;;

let re_equals = Str.regexp_string "=";;

(* TODO: use system *)
let copy_current_env () : env =
  let env = Hashtbl.create 1000 in

  let parse_env line =
    match Str.bounded_split_delim re_equals line 2 with
    | [key; value] -> Hashtbl.replace env key value
    | _ -> failwith (Printf.sprintf "Invalid environment mapping '%s'" line)
  in
  
  Array.iter parse_env (Unix.environment ());

  env
;;

let putenv name value env =
  (* Printf.fprintf stderr "Adding: %s=%s\n" name value; *)
  Hashtbl.replace env name value
;;

let find name env =
  try Hashtbl.find env name
  with Not_found -> raise_safe "Environment variable '%s' not set" name
;;

let find_opt name env =
  try Some (Hashtbl.find env name)
  with Not_found -> None
;;

let to_array env =
  let len = Hashtbl.length env in
  let arr = Array.make len "" in
  let item_to_array key value i = (arr.(i) <- key ^ "=" ^ value; i + 1) in
  let check_len = Hashtbl.fold item_to_array env 0 in
  assert (len == check_len);
  arr
;;
