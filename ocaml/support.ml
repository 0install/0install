(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Generic support code (not 0install-specific) *)

module StringMap = Map.Make(String);;

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
  end
;;

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

let safe_to_string = function
  | Safe_exception (msg, contexts) ->
      Some (msg ^ String.concat "\n" !contexts)
  | _ -> None
;;

let () = Printexc.register_printer safe_to_string;;

(** [handle_exceptions main] runs [main ()]. If it throws an exception it reports it in a
    user-friendly way. A [Safe_exception] is displayed with its context.
    If stack-traces are enabled, one will be displayed. If not then, if the exception isn't
    a [Safe_exception], the user is told how to enable them.
    On error, it calls [exit 1]. On success, it returns.
 *)
let handle_exceptions main =
  let args = Array.to_list (Sys.argv) in
  try
    match args with
    | prog :: "-v" :: args ->
        Printexc.record_backtrace true;
        main (prog :: args)
    | _ -> main args
  with
  | Safe_exception (msg, context) ->
      Printf.eprintf "%s\n" msg;
      List.iter (Printf.eprintf "%s\n") (List.rev !context);
      Printexc.print_backtrace stderr;
      exit 1
  | ex ->
      output_string stderr (Printexc.to_string ex);
      output_string stderr "\n";
      if not (Printexc.backtrace_status ()) then
        output_string stderr "(hint: run with OCAMLRUNPARAM=b to get a stack-trace)\n"
      else
        Printexc.print_backtrace stderr;
      exit 1
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

let on_windows = Filename.dir_sep <> "/"

(** The string used to separate paths (":" on Unix, ";" on Windows). *)
let path_sep = if on_windows then ";" else ":";;

(** Handy infix version of [Filename.concat]. *)
let (+/) : filepath -> filepath -> filepath = Filename.concat;;

(** [makedirs path mode] ensures that [path] is a directory, creating it and any missing parents (using [mode]) if not. *)
let rec makedirs (system:system) path mode =
  try (
    if (system#lstat path).Unix.st_kind = Unix.S_DIR then ()
    else raise_safe ("Not a directory: " ^ path)
  ) with Unix.Unix_error _ -> (
    let parent = (Filename.dirname path) in
    assert (path <> parent);
    makedirs system parent mode;
    system#mkdir path mode
  )
;;

let starts_with str prefix =
  let ls = String.length str in
  let lp = String.length prefix in
  if lp > ls then false else
    let rec loop i =
      if i = lp then true
      else if str.[i] <> prefix.[i] then false
      else loop (i + 1)
    in loop 0;;

let path_is_absolute path = starts_with path Filename.dir_sep;;

(** If the given path is relative, make it absolute by prepending the current directory to it. *)
let abspath (system:system) path =
  if path_is_absolute path then path
  else if starts_with path (Filename.current_dir_name ^ Filename.dir_sep) then
    system#getcwd () +/ String.sub path 2 ((String.length path) - 2)
  else (Sys.getcwd ()) +/ path
;;

(** Wrapper for [Sys.getenv] that gives a more user-friendly exception message. *)
let getenv_ex name =
  try Sys.getenv name
  with Not_found -> raise_safe ("Environment variable '" ^ name ^ "' not set")
;;

let re_dir_sep = Str.regexp_string Filename.dir_sep;;
let re_path_sep = Str.regexp_string path_sep;;

let find_in_path (system:system) name =
  let check p = if system#file_exists p then Some p else None in
  if Filename.is_implicit name then
    let test dir = check (dir +/ name) in
    first_match test (Str.split_delim re_path_sep (getenv_ex "PATH"))
  else
    check (abspath system name)
;;

let find_in_path_ex system name =
  match find_in_path system name with
  | Some path -> path
  | None -> raise_safe ("Not found in $PATH: " ^ name)
;;

let with_pipe fn =
  let (r, w) = Unix.pipe () in
  let result =
    try fn r w
    with ex ->
      Unix.close r;
      Unix.close w;
      raise ex
  in
  Unix.close r;
  Unix.close w;
  result
;;

(** Spawn a subprocess with the given arguments and call [fn channel] on its output. *)
let check_output (system:system) fn argv =
  Logging.log_info "Running %s" (String.concat " " (List.map String.escaped argv));
  try
    let (r, w) = Unix.pipe () in
    let child_pid =
      try system#create_process (List.hd argv) (Array.of_list argv) Unix.stdin w Unix.stdout
      with ex ->
        Unix.close r; Unix.close w; raise ex
    in
    Unix.close w;
    let in_channel = Unix.in_channel_of_descr r in
    let result =
      try fn in_channel
      with ex ->
        close_in in_channel;
        ignore (Unix.waitpid [] child_pid);
        raise ex
    in
    close_in in_channel;
    match snd (Unix.waitpid [] child_pid) with
    | Unix.WEXITED 0 -> result
    | Unix.WEXITED code -> raise_safe ("Child returned error exit status " ^ (string_of_int code))
    | _ -> raise_safe "Child failed"
  with Unix.Unix_error _ as ex ->
    let cmd = String.concat " " argv in
    raise (Safe_exception (Printexc.to_string ex, ref ["... trying to read output of: " ^ cmd]))
;;

(** Call [fn line] on each line of output from running the given sub-process. *)
let check_output_lines system fn argv =
  let process ch =
    try
      while true do
        fn (input_line ch)
      done
  with End_of_file -> () in
  check_output system process argv
;;

let split_pair re str =
  match Str.bounded_split_delim re str 2 with
  | [key; value] -> (key, value)
  | [_] -> failwith ("Not a pair '" ^ str ^ "'")
  | _ -> assert false

let re_section = Str.regexp "^[ \t]*\\[[ \t]*\\([^]]*\\)[ \t]*\\][ \t]*$"
let re_key_value = Str.regexp "^[ \t]*\\([^= ]+\\)[ \t]*=[ \t]*\\(.*\\)$"

let parse_ini (system:system) fn path =
  let read ch =
    let section = ref "" in
    try
      while true do
        let line = input_line ch in
        if Str.string_match re_section line 0 then
          let name = Str.matched_group 1 line in
          section := name;
        else if Str.string_match re_key_value line 0 then
          let key = Str.matched_group 1 line in
          let value = String.trim (Str.matched_group 2 line) in
          fn (!section, key, value)
      done
    with End_of_file -> () in
  system#with_open read path
;;
