(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Generic support code (not 0install-specific) *)

open Common

(** [finally cleanup x f] calls [f x] and then [cleanup x] (even if [f x] raised an exception) **)
let finally cleanup resource f =
  let result =
    try f resource
    with ex -> cleanup resource; raise ex in 
  let () = cleanup resource in
  result

let safe_to_string = function
  | Safe_exception (msg, contexts) ->
      Some (msg ^ "\n" ^ String.concat "\n" !contexts)
  | _ -> None
;;

let () = Printexc.register_printer safe_to_string;;

(** [handle_exceptions main args] runs [main args]. If it throws an exception it reports it in a
    user-friendly way. A [Safe_exception] is displayed with its context.
    If stack-traces are enabled, one will be displayed. If not then, if the exception isn't
    a [Safe_exception], the user is told how to enable them.
    On error, it calls [exit 1]. On success, it returns.
 *)
let handle_exceptions main args =
  try main args
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

(** Return the first non-[None] result of [fn item] for items in the list. *)
let rec first_match fn = function
  | [] -> None
  | (x::xs) -> match fn x with
      | Some _ as result -> result
      | None -> first_match fn xs;;

(** List the non-None results of [fn item] *)
let rec filter_map ~f = function
  | [] -> []
  | (x::xs) ->
      match f x with
      | None -> filter_map ~f xs
      | Some y -> y :: filter_map ~f xs

(** [makedirs path mode] ensures that [path] is a directory, creating it and any missing parents (using [mode]) if not. *)
let rec makedirs (system:system) path mode =
  match system#lstat path with
  | Some info ->
      if info.Unix.st_kind = Unix.S_DIR then ()
      else raise_safe "Not a directory: %s" path
  | None ->
      let parent = (Filename.dirname path) in
      assert (path <> parent);
      makedirs system parent mode;
      system#mkdir path mode

let starts_with str prefix =
  let ls = String.length str in
  let lp = String.length prefix in
  if lp > ls then false else
    let rec loop i =
      if i = lp then true
      else if str.[i] <> prefix.[i] then false
      else loop (i + 1)
    in loop 0;;

let ends_with str prefix =
  let ls = String.length str in
  let lp = String.length prefix in
  if lp > ls then false else
    let offset = ls - lp in
    let rec loop i =
      if i = lp then true
      else if str.[i + offset] <> prefix.[i] then false
      else loop (i + 1)
    in loop 0;;

let string_tail s i =
  let len = String.length s in
  if i > len then failwith ("String '" ^ s ^ "' too short to split at " ^ (string_of_int i))
  else String.sub s i (len - i)

let path_is_absolute path = not (Filename.is_relative path)

(** If the given path is relative, make it absolute by prepending the current directory to it. *)
let abspath (system:system) path =
  if path_is_absolute path then path
  else if starts_with path (Filename.current_dir_name ^ Filename.dir_sep) then
    system#getcwd () +/ String.sub path 2 ((String.length path) - 2)
  else (Sys.getcwd ()) +/ path
;;

(** Wrapper for [Sys.getenv] that gives a more user-friendly exception message. *)
let getenv_ex system name =
  match system#getenv name with
  | Some value -> value
  | None -> raise_safe "Environment variable '%s' not set" name
;;

let re_dir_sep = Str.regexp_string Filename.dir_sep;;
let re_path_sep = Str.regexp_string path_sep;;

(** Try to guess the full path of the executable that the user means.
    On Windows, we add a ".exe" extension if it's missing.
    If the name contains a dir_sep, just check that [abspath name] exists.
    Otherwise, search $PATH for it.
    On Windows, we also search '.' first. This mimicks the behaviour the Windows shell. *)
let find_in_path (system:system) name =
  let name = if on_windows && not (ends_with name ".exe") then name ^ ".exe" else name in
  let check p = if system#file_exists p then Some p else None in
  if String.contains name Filename.dir_sep.[0] then (
    (* e.g. "/bin/sh", "./prog" or "foo/bar" *)
    check (abspath system name)
  ) else (
    (* e.g. "python" *)
    let path = default "/usr/bin:/bin" (system#getenv "PATH") in
    let path_var = Str.split_delim re_path_sep path in
    let effective_path = if on_windows then system#getcwd () :: path_var else path_var in
    let test dir = check (dir +/ name) in
    first_match test effective_path
  )
;;

let find_in_path_ex system name =
  match find_in_path system name with
  | Some path -> path
  | None -> raise_safe "Not found in $PATH: %s" name
;;

(*
let with_pipe fn =
  let (r, w) = Unix.pipe () in
  finally (fun _ -> Unix.close r; Unix.close w) (r, w) fn
*)

(** Spawn a subprocess with the given arguments and call [fn channel] on its output. *)
let check_output ?stderr (system:system) fn (argv:string list) =
  Logging.log_info "Running %s" (String.concat " " (List.map String.escaped argv));
  let child_stderr = default Unix.stderr stderr in
  try
    let (r, w) = Unix.pipe () in
    let child_pid =
      finally Unix.close w (fun w ->
        try system#create_process (List.hd argv) (Array.of_list argv) Unix.stdin w child_stderr
        with ex ->
          Unix.close r; raise ex
      )
    in
    let result =
      finally close_in (Unix.in_channel_of_descr r) (fun in_channel ->
        try fn in_channel
        with ex ->
          (** User function raised an exception. Kill and reap the child. *)
          let () =
            try
              system#reap_child ~kill_first:Sys.sigterm child_pid
            with ex2 -> log_warning ~ex:ex2 "reap_child failed" in
          raise ex
      )
    in
    system#reap_child child_pid;
    result
  with
  | Unix.Unix_error _ as ex ->
      let cmd = String.concat " " argv in
      raise (Safe_exception (Printexc.to_string ex, ref ["... trying to read output of: " ^ cmd]))
  | Safe_exception _ as ex ->
      let cmd = String.concat " " argv in
      reraise_with_context ex "... trying to read output of: %s" cmd
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

(** [parse_ini system fn path] calls [fn section (key, value)] on each [key=value]
    line in [path]. *)
let parse_ini (system:system) fn path =
  let read ch =
    let handler = ref (fun x -> fn "" x) in
    try
      while true do
        let line = input_line ch in
        if Str.string_match re_section line 0 then
          let name = Str.matched_group 1 line in
          handler := fn name
        else if Str.string_match re_key_value line 0 then
          let key = Str.matched_group 1 line in
          let value = trim (Str.matched_group 2 line) in
          !handler (key, value)
      done
    with End_of_file -> () in
  system#with_open_in [Open_rdonly; Open_text] 0 path read
;;

let with_dev_null fn =
  let null_fd = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  finally Unix.close null_fd fn

let ro_rmtree (sys:system) root =
  if starts_with (sys#getcwd () ^ Filename.dir_sep) (root ^ Filename.dir_sep) then
    log_warning "Removing tree (%s) containing the current directory (%s) - this will not work on Windows" root (sys#getcwd ());

  let rec rmtree path =
    match sys#lstat path with
    | None -> failwith ("Path " ^ path ^ " does not exist!")
    | Some info ->
      match info.Unix.st_kind with
      | Unix.S_REG | Unix.S_LNK | Unix.S_BLK | Unix.S_CHR | Unix.S_SOCK | Unix.S_FIFO ->
          if on_windows then sys#chmod path 0o700;
          sys#unlink path
      | Unix.S_DIR -> (
          match sys#readdir path with
          | Success files ->
              sys#chmod path 0o700;
              Array.iter (fun leaf -> rmtree @@ path +/ leaf) files;
              sys#rmdir path
          | Problem ex -> raise ex
    ) in
  rmtree root

(** Copy [source] to [dest]. Error if [dest] already exists. *)
let copy_file (system:system) source dest mode =
  try
    system#with_open_in [Open_rdonly;Open_binary] 0 source (function ic ->
      system#with_open_out [Open_creat;Open_excl;Open_wronly;Open_binary] mode dest (function oc ->
        let bufsize = 4096 in
        let buf = String.create bufsize in
        try
          while true do
            let got = input ic buf 0 bufsize in
            if got = 0 then raise End_of_file;
            assert (got > 0);
            output oc buf 0 got
          done
        with End_of_file -> ()
      )
    )
  with Safe_exception _ as ex -> reraise_with_context ex "... copying %s to %s" source dest

(** Extract a sub-list. *)
let slice ~start ?stop lst =
  let from_start =
    let rec skip lst = function
      | 0 -> lst
      | i -> match lst with
          | [] -> failwith "list too short"
          | (_::xs) -> skip xs (i - 1)
    in skip lst start in
  match stop with
  | None -> from_start
  | Some stop ->
      let rec take lst = function
        | 0 -> []
        | i -> match lst with
            | [] -> failwith "list too short"
            | (x::xs) -> x :: take xs (i - 1)
      in take lst (stop - start)

let print (system:system) =
  let do_print msg = system#print_string (msg ^ "\n") in
  Printf.ksprintf do_print

(** Read all input from a channel. *)
let input_all ch =
  let b = Buffer.create 100 in
  let buf = String.create 256 in
  try
    while true do
      let got = input ch buf 0 256 in
      if got = 0 then
        raise End_of_file;
      Buffer.add_substring b buf 0 got
    done;
    failwith "!"
  with End_of_file -> Buffer.contents b
