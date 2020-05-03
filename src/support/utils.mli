(** Generic support code (not 0install-specific) *)

(** {2 Error handling} *)

(** [finally cleanup x f] calls [f x] and then [cleanup x] (even if [f x] raised an exception) **)
val finally_do : ('a -> unit) -> 'a -> ('a -> 'b) -> 'b

(** [handle_exceptions main args] runs [main args]. If it throws an exception it reports it in a
    user-friendly way. A [Safe_exn.T] is displayed with its context.
    If stack-traces are enabled, one will be displayed. If not then, if the exception isn't
    a [Safe_exn.T], the user is told how to enable them.
    On error, it calls [exit 1]. On success, it returns.
 *)
val handle_exceptions : ('a -> 'b) -> 'a -> 'b

(** Collections *)

(** Return the first non-[None] result of [fn item] for items in the list. *)
val first_match : ('a -> 'b option) -> 'a list -> 'b option

(** List the non-None results of [fn item] *)
val filter_map_array : ('a -> 'b option) -> 'a array -> 'b list

(** Extract a sub-list. *)
val slice : start:int -> ?stop:int -> 'a list -> 'a list

(** {2 System utilities} *)

(** [makedirs path mode] ensures that [path] is a directory, creating it and any missing parents (using [mode]) if not. *)
val makedirs : #Common.filesystem -> Common.filepath -> Unix.file_perm -> unit

(** Wrapper for [Sys.getenv] that gives a more user-friendly exception message. *)
val getenv_ex : < getenv : string -> 'a option; .. > -> string -> 'a

(** Try to guess the full path of the executable that the user means.
    On Windows, we add a ".exe" extension if it's missing.
    If the name contains a dir_sep, just check that [abspath name] exists.
    Otherwise, search $PATH for it.
    On Windows, we also search '.' first. This mimicks the behaviour the Windows shell. *)
val find_in_path : Common.system -> Common.filepath -> Common.filepath option
val find_in_path_ex : Common.system -> Common.filepath -> Common.filepath

(** Spawn a subprocess with the given arguments and call [fn channel] on its output. *)
val check_output :
  ?env:string array ->
  ?stderr:[< `FD of Unix.file_descr | `Stdout ] ->
  ?reaper:(int -> unit) ->
  #Common.processes -> (in_channel -> 'a) -> string list -> 'a

(** Read up to [n] bytes from [ch] (less if we hit end-of-file. *)
val read_upto : int -> in_channel -> string
val is_dir : < stat : Common.filepath -> Unix.stats option; .. > -> Common.filepath -> bool
val touch : #Common.system -> Common.filepath -> unit
val read_file : #Common.filesystem -> Common.filepath -> string

(** [parse_ini system fn path] calls [fn section (key, value)] on each [key=value]
    line in [path]. *)
val parse_ini :
  #Common.filesystem ->
  (string -> string * string -> unit) -> Common.filepath -> unit

val rmtree : even_if_locked:bool -> #Common.filesystem -> Common.filepath -> unit

(** Create a randomly-named subdirectory inside [parent]. *)
val make_tmp_dir :
  < mkdir : string -> int -> unit; .. > ->
  ?prefix:string -> ?mode:int -> string -> string

(** Copy from [ic] to [oc] until [End_of_file] *)
val copy_channel : in_channel -> out_channel -> unit

(** Copy [source] to [dest]. Error if [dest] already exists. *)
val copy_file : #Common.filesystem -> Common.filepath -> Common.filepath -> Unix.file_perm -> unit

(** {2 Pathnames} *)
val path_is_absolute : string -> bool

(** Normalize a path, e.g. A//B, A/./B and A/foo/../B all become A/B.
    It should be understood that this may change the meaning of the path
    if it contains symbolic links (use [realpath] instead if you care about that).
    Based on the Python version. *)
val normpath : string -> Common.filepath

(** If the given path is relative, make it absolute by prepending the current directory to it. *)
val abspath : #Common.filesystem -> Common.filepath -> Common.filepath

(** Get the canonical name of this path, resolving all symlinks. If a symlink cannot be resolved, treat it as
    a regular file. If there is a symlink loop, no resolution is done for the remaining components. *)
val realpath : #Common.filesystem -> Common.filepath -> Common.filepath

val re_dir_sep : Str.regexp    (* / on Unix *)
val re_path_sep : Str.regexp   (* : on Unix *)

(** {2 Dates and times} *)
val format_time : Unix.tm -> string
val format_time_pretty : Unix.tm -> string
val format_date : Unix.tm -> string

val format_size : Int64.t -> string
val atomic_hardlink : #Common.filesystem -> link_to:Common.filepath -> replace:Common.filepath -> unit
val stream_of_lines : string -> string Stream.t
val make_command : Common.system -> string list -> Lwt_process.command

(** Open this directory with the user's preferred file manager. *)
val xdg_open_dir : ?exec:bool -> Common.system -> Common.filepath -> unit

(** Don't wait for the result of this Lwt thread.
 * If it throws an exception, log it. *)
val async : (unit -> unit Lwt.t) -> unit

(** Create a switch, run [fn switch], then finally turn it off. *)
val with_switch : (Lwt_switch.t -> 'a Lwt.t) -> 'a Lwt.t

(** [memoize ~initial_size:n fn] returns a wrapped version of [fn] that caches each result returned. *)
val memoize : initial_size:int -> ('a -> 'b) -> ('a -> 'b)
