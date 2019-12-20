(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Common types and functions. This module is intended to be opened. *)

type filepath = string

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

(** Define an interface for interacting with the system, so we can replace it
    in unit-tests. *)
class type filesystem =
  object
    method with_open_in : open_flag list -> (in_channel -> 'a) -> filepath -> 'a
    method with_open_out : open_flag list -> mode:Unix.file_perm -> (out_channel -> 'a) -> filepath -> 'a
    method atomic_write : open_flag list -> mode:Unix.file_perm -> (out_channel -> 'a) -> filepath -> 'a
    method mkdir : filepath -> Unix.file_perm -> unit

    (** Returns [false] for a broken symlink. *)
    method file_exists : filepath -> bool

    method lstat : filepath -> Unix.stats option
    method stat : filepath -> Unix.stats option
    method unlink : filepath -> unit
    method rmdir : filepath -> unit
    method getcwd : filepath
    method chdir : filepath -> unit

    method hardlink : filepath -> filepath -> unit
    method rename : filepath -> filepath -> unit

    method readdir : filepath -> (string array, exn) result
    method chmod : filepath -> Unix.file_perm -> unit
    method set_mtime : filepath -> float -> unit
    method symlink : target:filepath -> newlink:filepath -> unit
    method readlink : filepath -> filepath option
  end

class type processes =
  object
    method exec : 'a. ?search_path:bool -> ?env:string array -> string list -> 'a
    method spawn_detach : ?search_path:bool -> ?env:string array -> string list -> unit
    method create_process : ?env:string array -> string list -> Unix.file_descr -> Unix.file_descr -> Unix.file_descr -> int

    (** [reap_child ?kill_first:signal child_pid] calls [waitpid] to collect the child.
        @raise Safe_exn.T if it didn't exit with a status of 0 (success). *)
    method reap_child : ?kill_first:int -> int -> unit

    (** Low-level interface, in case you need to process the exit status yourself. *)
    method waitpid_non_intr : int -> (int * Unix.process_status)
  end

class type environment =
  object
    method getenv : Env.name -> string option
    method environment : string array
  end

class type windows_api =
  object
    method get_appdata : string
    method get_local_appdata : string
    method get_common_appdata : string
    method read_registry_string : string -> string -> key64:bool -> string option  (* Reads from HKEY_LOCAL_MACHINE *)
    method read_registry_int : string -> string -> key64:bool -> int option        (* Reads from HKEY_LOCAL_MACHINE *)
  end

class type system =
  object
    inherit filesystem
    inherit processes
    inherit environment

    method argv : string array
    method time : float
    method isatty : Unix.file_descr -> bool

    (** True if we're on Unix and running as root; we must take care to avoid creating files in the wrong
     * place when running under sudo. *)
    method running_as_root : bool
    method platform : Platform.t
    method windows_api : windows_api option

    (** In dry-run mode, returns the underlying system. *)
    method bypass_dryrun : system
  end

let on_windows = Filename.dir_sep <> "/"

(** The string used to separate paths (":" on Unix, ";" on Windows). *)
let path_sep = if on_windows then ";" else ":"

(** Join a relative path onto a base.
    @raise Safe_exn.T if the second path is not relative. *)
let (+/) a b =
  if b = "" then
    a
  else if Filename.is_relative b then
    Filename.concat a b
  else
    Safe_exn.failf "Attempt to append absolute path: %s + %s" a b

let log_debug = Logging.log_debug
let log_info = Logging.log_info
let log_warning = Logging.log_warning

(** [with_errors_logged note f] is [f ()], except that if it raises any exception, the
    exception is logged at warning level with the message provided by [note]. The exception
    is not re-raised. *)
let with_errors_logged note f =
  Lwt.catch f
    (fun ex ->
       note (log_warning ~ex);
       Lwt.return ()
    )

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

let map_some fn = function
  | None -> None
  | Some x -> Some (fn x)

let (>>=) = Lwt.(>>=)
let (>|=) = Lwt.(>|=)
let return = Lwt.return
