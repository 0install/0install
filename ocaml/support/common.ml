(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Common types and functions. This module is intended to be opened. *)

module StringMap = Map.Make(String)

type filepath = string;;
type varname = string;;

class type system =
  object
    method time : unit -> float

    method with_open : (in_channel -> 'a) -> filepath -> 'a
    method mkdir : filepath -> Unix.file_perm -> unit
    method file_exists : filepath -> bool
    method lstat : filepath -> Unix.stats
    method exec : ?search_path:bool -> ?env:string array -> string list -> 'a
    method create_process : filepath -> string array -> Unix.file_descr -> Unix.file_descr -> Unix.file_descr -> int
    method getcwd : unit -> filepath
    method atomic_write : (out_channel -> 'a) -> filepath -> Unix.file_perm -> 'a

    method getenv : varname -> string option
  end
;;

exception Safe_exception of (string * string list ref);;

let on_windows = Filename.dir_sep <> "/"

(** The string used to separate paths (":" on Unix, ";" on Windows). *)
let path_sep = if on_windows then ";" else ":";;

(** Handy infix version of [Filename.concat]. *)
let (+/) : filepath -> filepath -> filepath = Filename.concat;;

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

let log_info = Logging.log_info
let log_warning = Logging.log_warning

(** [default d opt] unwraps option [opt], returning [d] if it was [None]. *)
let default d = function
  | None -> d
  | Some x -> x;;
