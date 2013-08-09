(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit
open General
open Support.Common

(* For temporary directory names *)
let () = Random.self_init ()

(* let () = Support.Logging.threshold := Support.Logging.Info *)

type mode = int

type dentry =
  | Dir of (mode * string list)
  | File of (mode * filepath)

module RealSystem = Support.System.RealSystem(Unix)
let real_system = new RealSystem.real_system

class fake_system tmpdir =
  let extra_files : dentry StringMap.t ref = ref StringMap.empty in

  let check_read path =
    if Filename.is_relative path then path
    else (
      try
        match StringMap.find path !extra_files with
        | Dir _ -> path
        | File (_mode, redirect_path) ->
            redirect_path
      with Not_found ->
        match tmpdir with
        | Some dir when Support.Utils.starts_with path dir -> path
        | _ -> failwith ("Attempt to read from " ^ path)
    ) in

  let check_write path =
    match tmpdir with
    | Some dir when Support.Utils.starts_with path dir -> path
    | _ -> failwith ("Attempt to write to " ^ path) in

  object (self : #system)
    val now = ref 0.0
    val mutable env = StringMap.empty
    val mutable stdout = None

    method collect_output (fn : unit -> unit) =
      let old_stdout = stdout in
      let b = Buffer.create 100 in
      stdout <- Some b;
      Support.Utils.finally (fun () -> stdout <- old_stdout) () fn;
      Buffer.contents b

    method print_string s =
      match stdout with
      | None -> failwith s
      | Some b -> Buffer.add_string b s

    val mutable argv = [| "0install" |]

    method argv () = argv
    method set_argv new_argv = argv <- new_argv

    method time () = !now

    method set_mtime path mtime = real_system#set_mtime (check_write path) mtime

    method with_open_in flags mode path fn = real_system#with_open_in flags mode (check_read path) fn
    method with_open_out flags mode path fn = real_system#with_open_out flags mode (check_write path) fn

    method mkdir path mode = real_system#mkdir (check_write path) mode

    method readdir path =
      try
        match StringMap.find path !extra_files with
        | Dir (_mode, items) -> Success (Array.of_list items)
        | _ -> failwith "Not a directory"
      with Not_found -> real_system#readdir (check_read path)

    method readlink path = real_system#readlink (check_read path)

    method chmod = failwith "chmod"

    method file_exists path =
      if path = "/usr/bin/0install" then true
      else if path = "C:\\Windows\\system32\\0install.exe" then true
      else if StringMap.mem path !extra_files then true
      else if tmpdir = None then false
      else real_system#file_exists (check_read path)

    method lstat path = real_system#lstat (check_read path)

    method stat = failwith "stat"
    method atomic_write open_flags fn path mode = real_system#atomic_write open_flags fn (check_write path) mode
    method unlink = failwith "unlink"
    method rmdir = failwith "rmdir"

    method exec = failwith "exec"
    method spawn_detach = failwith "spawn_detach"
    method create_process = failwith "exec"
    method reap_child = failwith "reap_child"

    method getcwd () =
      match tmpdir with
      | None -> "/root"
      | Some d -> d

    method getenv name =
      try Some (StringMap.find name env)
      with Not_found -> None

    method putenv name value =
      env <- StringMap.add name value env

    method platform () =
      let open Platform in {
        system = "Linux";
        release = "3.10.3-1-ARCH";
        machine = "x86_64";
      }

    method add_file path redirect_target =
      extra_files := StringMap.add path (File (0o644, redirect_target)) !extra_files

    method add_dir path items =
      extra_files := StringMap.add path (Dir (0o755, items)) !extra_files

    initializer
      match tmpdir with
      | Some dir -> self#putenv "ZEROINSTALL_PORTABLE_BASE" dir
      | None -> ()
  end
;;

let fake_log =
  object (_ : #Support.Logging.handler)
    val mutable record = []

    method reset () =
      record <- []

    method get () =
      record

    method handle ?ex level msg =
      if false then print_endline @@ "LOG: " ^ msg;
      record <- (ex, level, msg) :: record
  end

let collect_logging fn =
  let old_handler = !Support.Logging.handler in
  let () = Support.Logging.handler := (fake_log :> Support.Logging.handler) in
  Support.Utils.finally (fun () -> Support.Logging.handler := old_handler) () fn

let format_list l = "[" ^ (String.concat "; " l) ^ "]"
let equal_str_lists = assert_equal ~printer:format_list
let assert_str_equal = assert_equal ~printer:(fun x -> x)

let assert_raises_safe expected_msg fn =
  try Lazy.force fn; assert_failure ("Expected Safe_exception " ^ expected_msg)
  with Safe_exception (msg, _) ->
    assert_equal expected_msg msg

let assert_raises_fallback fn =
  try Lazy.force fn; assert_failure "Expected Fallback_to_Python"
  with Fallback_to_Python -> ()

let temp_dir_name =
  (* Filename.get_temp_dir_name doesn't exist under 3.12 *)
  try Sys.getenv "TEMP" with Not_found ->
    match Sys.os_type with
      | "Unix" | "Cygwin" -> "/tmp"
      | "Win32" -> "."
      | _ -> failwith "temp_dir_name: unknown filesystem"

let with_tmpdir fn () =
  let tmppath = temp_dir_name +/ Printf.sprintf "0install-test-%x" (Random.int 0x3fffffff) in
  Unix.mkdir tmppath 0o700;   (* will fail if already exists; OK for testing *)
  Support.Utils.finally (Support.Utils.ro_rmtree real_system) tmppath fn

let get_fake_config tmpdir =
  let system = new fake_system tmpdir in
  if tmpdir = None then system#putenv "HOME" "/home/testuser";
  if on_windows then
    system#putenv "PATH" "C:\\Windows\\system32;C:\\Windows"
  else
    system#putenv "PATH" "/usr/bin:/bin";
  let my_path =
    if on_windows then "C:\\Windows\\system32"
    else "/usr/bin/0install" in
  (Config.get_default_config (system :> system) my_path, system)
