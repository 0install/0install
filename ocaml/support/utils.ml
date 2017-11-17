(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Common

(* For temporary directory names *)
let () = Random.self_init ()

type path_component =
  | Filename of string  (* foo/ *)
  | ParentDir           (* ../ *)
  | CurrentDir          (* ./ *)
  | EmptyComponent      (* / *)

let finally_do cleanup resource f =
  let result =
    try f resource
    with ex -> cleanup resource; raise ex in
  let () = cleanup resource in
  result

let safe_to_string = function
  | Safe_exception (msg, contexts) ->
      Some (msg ^ "\n" ^ String.concat "\n" (List.rev !contexts))
  | _ -> None

let () = Printexc.register_printer safe_to_string

let handle_exceptions main args =
  try main args
  with
  | System_exit x -> exit x
  | Safe_exception (msg, context) as ex ->
      Printf.eprintf "%s\n" msg;
      List.iter (Printf.eprintf "%s\n") (List.rev !context);
      Printexc.print_backtrace stderr;
      Logging.dump_crash_log ~ex ();
      exit 1
  | ex ->
      output_string stderr (Printexc.to_string ex);
      output_string stderr "\n";
      if not (Printexc.backtrace_status ()) then
        output_string stderr "(hint: run with OCAMLRUNPARAM=b to get a stack-trace)\n"
      else
        Printexc.print_backtrace stderr;
      Logging.dump_crash_log ~ex ();
      exit 1

let rec first_match f = function
  | [] -> None
  | (x::xs) -> match f x with
      | Some _ as result -> result
      | None -> first_match f xs

let rec filter_map fn = function
  | [] -> []
  | (x::xs) ->
      match fn x with
      | None -> filter_map fn xs
      | Some y -> y :: filter_map fn xs

let filter_map_array fn arr =
  let result = ref [] in
  for i = 0 to Array.length arr - 1 do
    match fn arr.(i) with
    | Some item -> result := item :: !result
    | _ -> ()
  done;
  List.rev !result

let makedirs (system:#filesystem) path mode =
  let rec loop path =
    match system#stat path with
    | Some info ->
        if info.Unix.st_kind = Unix.S_DIR then ()
        else raise_safe "Not a directory: %s" path
    | None ->
        let parent = (Filename.dirname path) in
        assert (path <> parent);
        loop parent;
        system#mkdir path mode in
  try loop path
  with Safe_exception _ as ex -> reraise_with_context ex "... creating directory %s" path

let starts_with str prefix =
  let ls = String.length str in
  let lp = String.length prefix in
  if lp > ls then false else
    let rec loop i =
      if i = lp then true
      else if str.[i] <> prefix.[i] then false
      else loop (i + 1)
    in loop 0

let ends_with str prefix =
  let ls = String.length str in
  let lp = String.length prefix in
  if lp > ls then false else
    let offset = ls - lp in
    let rec loop i =
      if i = lp then true
      else if str.[i + offset] <> prefix.[i] then false
      else loop (i + 1)
    in loop 0

let string_tail s i =
  let len = String.length s in
  if i > len then failwith ("String '" ^ s ^ "' too short to split at " ^ (string_of_int i))
  else String.sub s i (len - i)

let path_is_absolute path = not (Filename.is_relative path)

(** Find the next "/" in [path]. On Windows, also accept "\\".
    Split the path at that point. Multiple slashes are treated as one.
    If there is no separator, returns [(path, "")]. *)
let split_path_str path =
  let l = String.length path in
  let is_sep c = (c = '/' || (on_windows && c = '\\')) in

  (* Skip any leading slashes and return the rest *)
  let rec find_rest i =
    if i < l then (
      if is_sep path.[i] then find_rest (i + 1)
      else string_tail path i
    ) else (
      ""
    ) in

  let rec find_slash i =
    if i < l then (
      if is_sep path.[i] then (String.sub path 0 i, find_rest (i + 1))
      else find_slash (i + 1)
    ) else (
      (path, "")
    )
  in
  find_slash 0

(** Split off the first component of a pathname.
    "a/b/c" -> (Filename "a", "b/c")
    "a"     -> (Filename "a", "")
    "/a"    -> (EmptyComponent, "a")
    "/"     -> (EmptyComponent, "")
    ""      -> (CurrentDir, "")
  *)
let split_first path =
  if path = "" then
    (CurrentDir, "")
  else (
    let (first, rest) = split_path_str path in
    let parsed =
      if first = Filename.parent_dir_name then ParentDir
      else if first = Filename.current_dir_name then CurrentDir
      else if first = "" then EmptyComponent
      else Filename first in
    (parsed, rest)
  )

let normpath path : filepath =
  let rec explode path =
    match split_first path with
    | CurrentDir, "" -> []
    | CurrentDir, rest -> explode rest
    | first, "" -> [first]
    | first, rest -> first :: explode rest in

  let rec remove_parents = function
    | checked, [] -> checked
    | (Filename _name :: checked), (ParentDir :: rest) -> remove_parents (checked, rest)
    | checked, (first :: rest) -> remove_parents ((first :: checked), rest) in

  let to_string = function
    | Filename name -> name
    | ParentDir -> Filename.parent_dir_name
    | EmptyComponent -> ""
    | CurrentDir -> assert false in

  String.concat Filename.dir_sep @@ List.rev_map to_string @@ remove_parents ([], explode path)

let abspath (system:#filesystem) path =
  normpath (
    if path_is_absolute path then path
    else system#getcwd +/ path
  )

let getenv_ex system name =
  match system#getenv name with
  | Some value -> value
  | None -> raise_safe "Environment variable '%s' not set" name

let re_dash = Str.regexp_string "-"
let re_slash = Str.regexp_string "/"
let re_space = Str.regexp_string " "
let re_tab = Str.regexp_string "\t"
let re_dir_sep = Str.regexp_string Filename.dir_sep
let re_path_sep = Str.regexp_string path_sep
let re_colon = Str.regexp_string ":"
let re_equals = Str.regexp_string "="
let re_semicolon = Str.regexp_string ";"

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
    let effective_path = if on_windows then system#getcwd :: path_var else path_var in
    let test dir = check (dir +/ name) in
    first_match test effective_path
  )

let find_in_path_ex system name =
  match find_in_path system name with
  | Some path -> path
  | None -> raise_safe "Not found in $PATH: %s" name

let check_output ?env ?stderr ?reaper (system:#processes) fn (argv:string list) =
  try
    let (r, w) = Unix.pipe () in
    let child_pid =
      finally_do Unix.close w (fun w ->
        try
          let child_stderr =
            match stderr with
            | None -> Unix.stderr
            | Some (`FD fd) -> fd
            | Some (`Stdout) -> w in
          system#create_process ?env argv Unix.stdin w child_stderr
        with ex ->
          Unix.close r; raise ex
      )
    in
    let result =
      finally_do close_in (Unix.in_channel_of_descr r) (fun in_channel ->
        try fn in_channel
        with ex ->
          (* User function raised an exception. Kill and reap the child. *)
          let () =
            try
              system#reap_child ~kill_first:Sys.sigterm child_pid
            with ex2 ->
              let args = Logging.format_argv_for_logging argv in
              log_warning ~ex:ex2 "reap_child failed (%s)" args in
          raise ex
      )
    in
    begin match reaper with
    | None -> system#reap_child child_pid
    | Some reap_child -> reap_child child_pid end;
    result
  with
  | Unix.Unix_error _ as ex ->
      let cmd = Logging.format_argv_for_logging argv in
      raise (Safe_exception (Printexc.to_string ex, ref ["... trying to read output of: " ^ cmd]))
  | Safe_exception _ as ex ->
      let cmd = Logging.format_argv_for_logging argv in
      reraise_with_context ex "... trying to read output of: %s" cmd

let split_pair re str =
  match Str.bounded_split_delim re str 2 with
  | [key; value] -> (key, value)
  | [_] -> raise_safe "Not a pair '%s'" str
  | _ -> assert false

let re_section = Str.regexp "^[ \t]*\\[[ \t]*\\([^]]*\\)[ \t]*\\][ \t]*$"
let re_key_value = Str.regexp "^[ \t]*\\([^= ]+\\)[ \t]*=[ \t]*\\(.*\\)$"

let parse_ini (system:#filesystem) fn =
  system#with_open_in [Open_rdonly; Open_text] (fun ch ->
    let handler = ref (fun x -> fn "" x) in
    try
      while true do
        let line = input_line ch in
        if Str.string_match re_section line 0 then
          let name = Str.matched_group 1 line in
          handler := fn name
        else if Str.string_match re_key_value line 0 then
          let key = Str.matched_group 1 line in
          let value = String.trim (Str.matched_group 2 line) in
          !handler (key, value)
      done
    with End_of_file -> ()
  )

let rmtree ~even_if_locked (sys:#filesystem) root =
  if starts_with (sys#getcwd ^ Filename.dir_sep) (root ^ Filename.dir_sep) then
    log_warning "Removing tree (%s) containing the current directory (%s) - this will not work on Windows" root sys#getcwd;

  try
    let rec rmtree path =
      match sys#lstat path with
      | None -> failwith ("Path " ^ path ^ " does not exist!")
      | Some info ->
        match info.Unix.st_kind with
        | Unix.S_REG | Unix.S_LNK | Unix.S_BLK | Unix.S_CHR | Unix.S_SOCK | Unix.S_FIFO ->
            if on_windows && even_if_locked then sys#chmod path 0o700;
            sys#unlink path
        | Unix.S_DIR -> (
            if even_if_locked then
              sys#chmod path 0o700;
            match sys#readdir path with
            | Success files ->
                Array.iter (fun leaf -> rmtree @@ path +/ leaf) files;
                sys#rmdir path
            | Problem ex -> raise_safe "Can't read directory '%s': %s" path (Printexc.to_string ex)
      ) in
    rmtree root
  with Safe_exception _ as ex -> reraise_with_context ex "... trying to delete directory %s" root

let copy_channel ic oc =
  let bufsize = 4096 in
  let buf = Bytes.create bufsize in
  try
    while true do
      let got = input ic buf 0 bufsize in
      if got = 0 then raise End_of_file;
      assert (got > 0);
      output oc buf 0 got
    done
  with End_of_file -> ()

let copy_file (system:#filesystem) source dest mode =
  try
    source |> system#with_open_in [Open_rdonly;Open_binary] (fun ic ->
      dest |> system#with_open_out [Open_creat;Open_excl;Open_wronly;Open_binary] ~mode (copy_channel ic)
    )
  with Safe_exception _ as ex -> reraise_with_context ex "... copying %s to %s" source dest

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
      in take from_start (stop - start)

let print (system:system) fmt =
  Format.kasprintf system#print_string (fmt ^^ "@.")

let realpath (system:#filesystem) path =
  let (+/) = Filename.concat in   (* Faster version, since we know the path is relative *)

  (* Based on Python's version *)
  let rec join_realpath path rest seen =
    (* Printf.printf "join_realpath <%s> + <%s>\n" path rest; *)
    (* [path] is already a realpath (no symlinks). [rest] is the bit to join to it. *)
    match split_first rest with
    | Filename name, rest -> (
      (* path + name/rest *)
      let newpath = path +/ name in
      match system#readlink newpath with
      | Some target ->
          (* path + symlink/rest *)
          begin match StringMap.find newpath seen with
          | Some (Some cached_path) -> join_realpath cached_path rest seen
          | Some None -> (normpath (newpath +/ rest), false)    (* Loop; give up *)
          | None ->
              (* path + symlink/rest -> realpath(path + target) + rest *)
              match join_realpath path target (StringMap.add newpath None seen) with
              | path, false ->
                  (normpath (path +/ rest), false)   (* Loop; give up *)
              | path, true -> join_realpath path rest (StringMap.add newpath (Some path) seen)
          end
      | None ->
          (* path + name/rest -> path/name + rest (name is not a symlink) *)
          join_realpath newpath rest seen
    )
    | CurrentDir, "" ->
        (path, true)
    | CurrentDir, rest ->
      (* path + ./rest *)
      join_realpath path rest seen
    | ParentDir, rest ->
      (* path + ../rest *)
      if String.length path > 0 then (
        let name = Filename.basename path in
        let path = Filename.dirname path in
        if name = Filename.parent_dir_name then
          join_realpath (path +/ name +/ name) rest seen    (* path/.. +  ../rest -> path/../.. + rest *)
        else
          join_realpath path rest seen                      (* path/name + ../rest -> path + rest *)
      ) else (
        join_realpath Filename.parent_dir_name rest seen    (* "" + ../rest -> .. + rest *)
      )
    | EmptyComponent, rest ->
        (* [rest] is absolute; discard [path] and start again *)
        join_realpath Filename.dir_sep rest seen
  in

  try
    if on_windows then
      abspath system path
    else (
      fst @@ join_realpath system#getcwd path StringMap.empty
    )
  with Safe_exception _ as ex -> reraise_with_context ex "... in realpath(%s)" path

let format_time t =
  let open Unix in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (1900 + t.tm_year)
    (t.tm_mon + 1)
    t.tm_mday
    t.tm_hour
    t.tm_min
    t.tm_sec

(* Separates date and time with a space and doesn't show seconds *)
let format_time_pretty t =
  let open Unix in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d"
    (1900 + t.tm_year)
    (t.tm_mon + 1)
    t.tm_mday
    t.tm_hour
    t.tm_min

let format_date t =
  let open Unix in
  Printf.sprintf "%04d-%02d-%02d"
    (1900 + t.tm_year)
    (t.tm_mon + 1)
    t.tm_mday

let read_upto n ch : string =
  let buf = Bytes.create n in
  let saved = ref 0 in
  try
    while !saved < n do
      let got = input ch buf !saved (n - !saved) in
      if got = 0 then
        raise End_of_file;
      assert (got > 0);
      saved := !saved + got
    done;
    Bytes.unsafe_to_string buf
  with End_of_file ->
    Bytes.sub buf 0 !saved |> Bytes.unsafe_to_string

let is_dir system path =
  match system#stat path with
  | None -> false
  | Some info -> info.Unix.st_kind = Unix.S_DIR

let touch (system:#system) path =
  system#with_open_out [Open_wronly; Open_creat] ~mode:0o600 ignore path;
  system#set_mtime path @@ system#time   (* In case file already exists *)

let read_file (system:#filesystem) path =
  match system#stat path with
  | None -> raise_safe "File '%s' doesn't exist" path
  | Some info ->
      let buf = Bytes.create (info.Unix.st_size) in
      path |> system#with_open_in [Open_rdonly;Open_binary] (fun ic ->
        really_input ic buf 0 info.Unix.st_size
      );
      Bytes.unsafe_to_string buf

let safe_int_of_string s =
  try int_of_string s
  with Failure msg -> raise_safe "Invalid integer '%s' (%s)" s msg

let make_tmp_dir system ?(prefix="tmp-") ?(mode=0o700) parent =
  let rec mktmp = function
    | 0 -> raise_safe "Failed to generate temporary directroy name!"
    | n ->
        try
          let tmppath = parent +/ Printf.sprintf "%s%x" prefix (Random.int 0x3fffffff) in
          system#mkdir tmppath mode;
          tmppath
        with Unix.Unix_error (Unix.EEXIST, _, _) -> mktmp (n - 1) in
  mktmp 10

let format_size size =
  let size = Int64.to_float size in
  let spf = Printf.sprintf in
  if size < 2048. then spf "%.0f bytes" size
  else (
    let rec check size units =
      let size = size /. 1024. in
      match units with
      | u::rest ->
          if size < 2048. || rest = [] then
            spf "%.1f %s" size u
          else check size rest
      | [] -> assert false in
    check size ["KB"; "MB"; "GB"; "TB"]
  )

(** Remove [replace] and replace it with a hardlink to [source]. If possible, ensure
    that there is no point where [replace] does not exist.
    May use (overwrite) [replace.new] as a temporary file. *)
let atomic_hardlink system ~link_to ~replace =
  if on_windows then (
    if system#file_exists replace then
      system#unlink replace;
    system#hardlink link_to replace
  ) else (
    let tmp = (replace ^ ".new") in
    if system#file_exists tmp then
      system#unlink tmp;
    system#hardlink link_to tmp;
    system#rename tmp replace
  )

let stream_of_lines data =
  let i = ref 0 in
  Stream.from (fun _count ->
      if !i = String.length data then None
      else (
        let nl =
          try String.index_from data !i '\n'
          with Not_found ->
            raise_safe "Extra data at end (no endline): %s" (String.escaped @@ string_tail data !i) in
        let line = String.sub data !i (nl - !i) in
        i := nl + 1;
        Some line
      )
  )

let make_command system args =
  log_info "Will run: %s" (Logging.format_argv_for_logging args);
  (find_in_path_ex system (List.hd args), Array.of_list args)

let xdg_open_dir ?(exec=false) (system:system) path =
  (* xdg-open has no "safe" mode, so check we're not "opening" an application. *)
  if system#file_exists (path +/ "AppRun") then
    raise_safe "Documentation directory '%s' is an AppDir; refusing to open" path
  else if exec then
    system#exec ~search_path:true ["xdg-open"; path]
  else
    system#spawn_detach ~search_path:true ["xdg-open"; path]

let async fn =
  Lwt.ignore_result (
    Lwt.catch fn (fun ex ->
      log_warning ~ex "Unhandled error from Lwt thread"; Lwt.fail ex
    )
  )

let with_switch fn =
  let switch = Lwt_switch.create () in
  Lwt.finalize
    (fun () -> fn switch)
    (fun () -> Lwt_switch.turn_off switch)

let memoize ~initial_size create =
  let cache = Hashtbl.create initial_size in
  fun key ->
    try Hashtbl.find cache key
    with Not_found ->
      let value = create key in
      Hashtbl.add cache key value;
      value
