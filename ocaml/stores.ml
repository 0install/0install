(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support;;

type stores = string list;;

type digest = (string * string);;

exception Not_stored of string;;

let format_digest (alg, value) =
  let s = match alg with
  | "sha1" | "sha1new" | "sha256" -> alg ^ "=" ^ value
  | _ -> alg ^ "_" ^ value in
  (* validate *)
  s;;

let lookup_digest stores digest =
  let check_store store = (
    let path = Filename.concat store (format_digest digest) in
    if Sys.file_exists path then Some path else None
  ) in first_match check_store stores;;

let lookup_maybe digests stores = first_match (lookup_digest stores) digests

let lookup_any digests stores =
  match lookup_maybe digests stores with
  | Some path -> path
  | None ->
      let str_digests = String.concat ", " (List.map format_digest digests) in
      let str_stores = String.concat ", " stores in
      raise (Not_stored ("Item with digests " ^ str_digests ^ " not found in stores. Searched " ^ str_stores));;

let get_default_stores basedir_config =
  List.map (fun prefix -> prefix +/ "0install.net" +/ "implementations") basedir_config.Basedir.cache
;;
