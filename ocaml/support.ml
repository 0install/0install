(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Generic support code (not 0install-specific) *)

module StringMap = Map.Make(String);;

type filepath = string;;
type varname = string;;

(** An error that should be reported to the user without a stack-trace (i.e. it
    does not indicate a bug).
    The list is an optional list of context strings, outermost first, saying what
    we were doing when the exception occurred. This list gets extended as the exception
    propagates.
 *)
exception Safe_exception of (string * string list ref);;

(** Convenient way to create a new [Safe_exception] with no initial context. *)
let raise_safe msg = raise (Safe_exception (msg, ref []));;

(** Add the additional explanation [context] to the exception and rethrow it.
    [ex] should be a [Safe_exception] (if not, [context] is written as a warning to [stderr]).
  *)
let reraise_with_context ex context =
  let () = match ex with
  | Safe_exception (_, old_contexts) -> old_contexts := context :: !old_contexts
  | _ -> Printf.eprintf "warning: Attempt to add note '%s' to non-Safe_exception!" context
  in raise ex
;;

(** [with_open file fn] opens [file], calls [fn handle], and then closes it again. *)
let with_open file fn =
  let ch =
    try open_in file
    with Sys_error msg -> raise_safe msg
  in
  let result = try fn ch with ex -> close_in ch; raise ex in
  let () = close_in ch in
  result
;;

(** [default d opt] unwraps option [opt], returning [d] if it was [None]. *)
let default d = function
  | None -> d
  | Some x -> x;;

(** Return the first non-[None] result of [fn item] for items in the list. *)
let rec first_match fn = function
  | [] -> None
  | (x::xs) -> match fn x with
      | Some _ as result -> result
      | None -> first_match fn xs;;

(** The string used to separate paths (":" on Unix, ";" on Windows). *)
let path_sep = if Filename.dir_sep = "/" then ":" else ";";;

(** Handy infix version of [Filename.concat]. *)
let (+/) : filepath -> filepath -> filepath = Filename.concat;;

(** [makedirs path mode] ensures that [path] is a directory, creating it and any missing parents (using [mode]) if not. *)
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

(** If the given path is relative, make it absolute by prepending the current directory to it. *)
let abspath path =
  if path.[0] = '/' then path
  else (Sys.getcwd ()) +/ path
;;
