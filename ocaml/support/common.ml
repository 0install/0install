(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Common types and functions. This module is intended to be opened. *)

type 'a result =
  | Success of 'a
  | Problem of exn

(** [a @@ b @@ c] is an alternative way to write [a (b (c))]. It's like [$] in Haskell. **)
(* external ( @@ ) : ('a -> 'b) -> 'a -> 'b = "%apply" *)
IFDEF OCAML_LT_4_01 THEN
let (@@) a b = a b
let (|>) f x = x f
ENDIF

type filepath = string
type varname = string

type yes_no_maybe = Yes | No | Maybe

exception Safe_exception of (string * string list ref)

(** Raise this to exit the program. Allows finally blocks to run. *)
exception System_exit of int

module Platform =
  struct
    type t = {
      os : string;          (** OS, e.g. "Linux" *)
      release : string;     (** OS version, e.g. "3.10.3-1-ARCH" *)
      machine : string;     (** CPU type, e.g. "x86_64" *)
    }
  end

(** Convenient way to create a new [Safe_exception] with no initial context. *)
let raise_safe fmt =
  let do_raise msg = raise @@ Safe_exception (msg, ref []) in
  Printf.ksprintf do_raise fmt

module StringMap = struct
  include Map.Make(String)
  let find_nf = find
  let find_safe key map = try find key map with Not_found -> raise_safe "BUG: Key '%s' not found in StringMap!" key
  let find key map = try Some (find key map) with Not_found -> None
  let map_bindings fn map = fold (fun key value acc -> fn key value :: acc) map []
end
module StringSet = Set.Make(String)

(** Define an interface for interacting with the system, so we can replace it
    in unit-tests. *)
class type system =
  object
    method argv : string array
    method print_string : string -> unit
    method time : float
    method isatty : Unix.file_descr -> bool

    method with_open_in : open_flag list -> Unix.file_perm -> filepath -> (in_channel -> 'a) -> 'a
    method with_open_out : open_flag list -> Unix.file_perm -> filepath -> (out_channel -> 'a) -> 'a
    method mkdir : filepath -> Unix.file_perm -> unit
    (** Returns [false] for a broken symlink. *)
    method file_exists : filepath -> bool
    method lstat : filepath -> Unix.stats option
    method stat : filepath -> Unix.stats option
    method unlink : filepath -> unit
    method rmdir : filepath -> unit
    method getcwd : filepath
    method chdir : filepath -> unit
    method atomic_write : open_flag list -> filepath -> mode:Unix.file_perm -> (out_channel -> 'a) -> 'a

    method hardlink : filepath -> filepath -> unit
    method rename : filepath -> filepath -> unit

    method readdir : filepath -> string array result
    method chmod : filepath -> Unix.file_perm -> unit
    method set_mtime : filepath -> float -> unit
    method symlink : target:filepath -> newlink:filepath -> unit
    method readlink : filepath -> filepath option

    method exec : ?search_path:bool -> ?env:string array -> string list -> 'a
    method spawn_detach : ?search_path:bool -> ?env:string array -> string list -> unit
    method create_process : ?env:string array -> string list -> Unix.file_descr -> Unix.file_descr -> Unix.file_descr -> int
    (** [reap_child ?kill_first:signal child_pid] calls [waitpid] to collect the child.
        @raise Safe_exception if it didn't exit with a status of 0 (success). *)
    method reap_child : ?kill_first:int -> int -> unit
    (** Low-level interface, in case you need to process the exit status yourself. *)
    method waitpid_non_intr : int -> (int * Unix.process_status)

    method getenv : varname -> string option
    method environment : string array

    (** True if we're on Unix and running as root; we must take care to avoid creating files in the wrong
     * place when running under sudo. *)
    method running_as_root : bool
    method platform : Platform.t

    (** In dry-run mode, returns the underlying system. *)
    method bypass_dryrun : system
  end

let on_windows = Filename.dir_sep <> "/"

(** The string used to separate paths (":" on Unix, ";" on Windows). *)
let path_sep = if on_windows then ";" else ":"

(** Join a relative path onto a base.
    @raise Safe_exception if the second path is not relative. *)
let (+/) a b =
  if b = "" then
    a
  else if Filename.is_relative b then
    Filename.concat a b
  else
    raise_safe "Attempt to append absolute path: %s + %s" a b

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

let log_debug = Logging.log_debug
let log_info = Logging.log_info
let log_warning = Logging.log_warning

(** [default d opt] unwraps option [opt], returning [d] if it was [None]. *)
let default d = function
  | None -> d
  | Some x -> x

(** A null coalescing operator. *)
let (|?) maybe default =
  match maybe with
  | Some v -> v
  | None -> Lazy.force default

let if_some fn = function
  | None -> ()
  | Some x -> fn x

let pipe_some fn = function
  | None -> None
  | Some x -> fn x

(** {2 Backported from OCaml 4} **)

let trim s =
  let is_space = function
    | ' ' | '\012' | '\n' | '\r' | '\t' -> true
    | _ -> false in
  let open String in
  let len = length s in
  let i = ref 0 in
  while !i < len && is_space (unsafe_get s !i) do
    incr i
  done;
  let j = ref (len - 1) in
  while !j >= !i && is_space (unsafe_get s !j) do
    decr j
  done;
  if !i = 0 && !j = len - 1 then
    s
  else if !j >= !i then
    sub s !i (!j - !i + 1)
  else
    ""
