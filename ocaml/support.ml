(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

module StringMap = Map.Make(String);;

type filepath = string;;
type varname = string;;

(** An error that should be reported to the user without a stack-trace (i.e. it
 * does not indicate a bug).
 * The list is an optional list of context strings, outermost first, saying what
 * we were doing when the exception occured. This list gets extended as the exception
 * propagates.
 *)
exception Safe_exception of (string * string list ref);;

let raise_safe msg = raise (Safe_exception (msg, ref []));;

let reraise_with_context ex context =
  let () = match ex with
  | Safe_exception (_, old_contexts) -> old_contexts := context :: !old_contexts
  | _ -> Printf.eprintf "warning: Attempt to add note '%s' to non-Safe_exception!" context
  in raise ex
;;

let with_open file fn =
  let ch =
    try open_in file
    with Sys_error msg -> raise_safe msg
  in
  let result = try fn ch with exn -> close_in ch; raise exn in
  let () = close_in ch in
  result
;;

let default d = function
  | None -> d
  | Some x -> x;;

let rec first_match fn = function
  | [] -> None
  | (x::xs) -> match fn x with
      | Some _ as result -> result
      | None -> first_match fn xs;;

let path_sep = if Filename.dir_sep = "/" then ":" else ";";;

let (+/) : filepath -> filepath -> filepath = Filename.concat;;

let rec makedirs path mode =
  try (
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then ()
    else raise_safe ("Not a directory: " ^ path)
  ) with Unix.Unix_error _ -> (
    let parent = (Filename.dirname path) in
    assert (path <> parent);
    makedirs parent mode;
    Unix.mkdir path mode
  )
;;

let abspath path =
  if path.[0] = '/' then path
  else (Sys.getcwd ()) +/ path
;;
