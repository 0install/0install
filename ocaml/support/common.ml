(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Common types and functions. This module is intended to be opened. *)

module StringMap = Map.Make(String)
module StringSet = Set.Make(String)

type 'a result =
  | Success of 'a
  | Failure of exn

(** [a @@ b @@ c] is an alternative way to write [a (b (c))]. It's like [$] in Haskell. **)
external ( @@ ) : ('a -> 'b) -> 'a -> 'b = "%apply"

(** [a |> b] is an alternative way to write (b a) **)
external (|>) : 'a -> ('a -> 'b) -> 'b = "%revapply";;

type filepath = string
type varname = string

class type system =
  object
    method time : unit -> float

    method with_open_in : open_flag list -> Unix.file_perm -> filepath -> (in_channel -> 'a) -> 'a
    method with_open_out : open_flag list -> Unix.file_perm -> filepath -> (out_channel -> 'a) -> 'a
    method mkdir : filepath -> Unix.file_perm -> unit
    method file_exists : filepath -> bool
    method lstat : filepath -> Unix.stats option
    method stat : filepath -> Unix.stats option
    method unlink : filepath -> unit
    method rmdir : filepath -> unit
    method getcwd : unit -> filepath
    method atomic_write : open_flag list -> (out_channel -> 'a) -> filepath -> Unix.file_perm -> 'a
    method readdir : filepath -> string array result
    method chmod : filepath -> Unix.file_perm -> unit

    method exec : ?search_path:bool -> ?env:string array -> string list -> 'a
    method create_process : filepath -> string array -> Unix.file_descr -> Unix.file_descr -> Unix.file_descr -> int
    (** [reap_child ?kill_first:signal child_pid] calls [waitpid] to collect the child.
        @raise Safe_exception if it didn't exit with a status of 0 (success). *)
    method reap_child : ?kill_first:int -> int -> unit

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
let raise_safe fmt =
  let do_raise msg = raise @@ Safe_exception (msg, ref []) in
  Printf.ksprintf do_raise fmt

(** Add the additional explanation [context] to the exception and rethrow it.
    [ex] should be a [Safe_exception] (if not, [context] is written as a warning to [stderr]).
  *)
let reraise_with_context ex fmt =
  let do_raise context =
    let () = match ex with
    | Safe_exception (_, old_contexts) -> old_contexts := context :: !old_contexts
    | _ -> Printf.eprintf "warning: Attempt to add note '%s' to non-Safe_exception!" context
    in
    raise ex
  in Printf.ksprintf do_raise fmt
;;

let log_info = Logging.log_info
let log_warning = Logging.log_warning

(** [default d opt] unwraps option [opt], returning [d] if it was [None]. *)
let default d = function
  | None -> d
  | Some x -> x;;
