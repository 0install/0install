(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit
open Zeroinstall.General
open Support.Common
module Config = Zeroinstall.Config

(* For temporary directory names *)
let () = Random.self_init ()

(* let () = Support.Logging.threshold := Support.Logging.Info *)

type mode = int

type dentry =
  | Dir of (mode * string list)
  | File of (mode * filepath)

module RealSystem = Support.System.RealSystem(Unix)
let real_system = new RealSystem.real_system

let build_dir = Support.Utils.handle_exceptions (fun () -> Support.Utils.getenv_ex real_system "OCAML_BUILDDIR") ()

let make_stat st_perm kind =
  let open Unix in {
    st_perm;
    st_dev = 0;
    st_ino = 0;
    st_kind = kind;
    st_nlink = 1;
    st_uid = 0;
    st_gid = 0;
    st_rdev = 0;
    st_size = 100;
    st_atime = 0.0;
    st_mtime = 0.0;
    st_ctime = 0.0;
  }

exception Would_exec of (bool * string array option * string list)
exception Would_spawn of (bool * string array option * string list)

let src_dir = Filename.dirname @@ Filename.dirname @@ Sys.getcwd ()
let test_0install = src_dir +/ "0install"           (* Pretend we're running from here so we find 0launch *)

class fake_system tmpdir =
  let extra_files : dentry StringMap.t ref = ref StringMap.empty in

  let check_read path =
    (* log_info "check_read(%s)" path; *)
    if Filename.is_relative path then path
    else (
      try
        match StringMap.find path !extra_files with
        | Dir _ -> path
        | File (_mode, redirect_path) ->
            redirect_path
      with Not_found ->
        if Support.Utils.starts_with path src_dir then path
        else (
          match tmpdir with
          | Some dir when Support.Utils.starts_with path dir -> path
          | _ -> raise_safe "Attempt to read from '%s'" path
        )
    ) in

  let check_write path =
    match tmpdir with
    | Some dir when Support.Utils.starts_with path dir -> path
    | _ -> raise_safe "Attempt to write to '%s'" path in

  (* It's OK to check whether these paths exists. We just say they don't,
     unless they're in extra_files (check there first). *)
  let hidden_subtree path =
    if Support.Utils.starts_with path "/var" then
      match tmpdir with
      | None -> true
      | Some tmpdir -> not (Support.Utils.starts_with path tmpdir)
    else false in

  object (self : #system)
    val now = ref @@ float_of_int @@ 101 * days
    val mutable env = StringMap.empty
    val mutable stdout = None
    val mutable spawn_handler = None

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

    val mutable argv = [| test_0install |]

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

    method readlink path =
      if StringMap.mem path !extra_files then None    (* Not a link *)
      else real_system#readlink (check_read path)

    method chmod = failwith "chmod"

    method file_exists path =
      if path = "/usr/bin/0install" then true
      else if path = "C:\\Windows\\system32\\0install.exe" then true
      else if StringMap.mem path !extra_files then true
      else if StringMap.mem (Filename.dirname path) !extra_files then false
      else if tmpdir = None then false
      else real_system#file_exists (check_read path)

    method lstat path =
      try
        let open Unix in
        match StringMap.find path !extra_files with
        | Dir (mode, _items) -> Some (make_stat mode S_DIR)
        | File (_mode, target) -> real_system#lstat target
      with Not_found ->
        if hidden_subtree path then None
        else real_system#lstat (check_read path)

    method stat path =
      try
        let open Unix in
        match StringMap.find path !extra_files with
        | Dir (mode, _items) -> Some (make_stat mode S_DIR)
        | File (_mode, target) -> real_system#stat target
      with Not_found ->
        if hidden_subtree path then None
        else real_system#stat (check_read path)

    method atomic_write open_flags fn path mode = real_system#atomic_write open_flags fn (check_write path) mode
    method atomic_hardlink ~link_to ~replace = real_system#atomic_hardlink ~link_to:(check_read link_to) ~replace:(check_write replace)
    method unlink = failwith "unlink"
    method rmdir = failwith "rmdir"

    method exec ?(search_path = false) ?env argv =
      raise (Would_exec (search_path, env, argv))

    method spawn_detach ?(search_path = false) ?env argv =
      raise (Would_spawn (search_path, env, argv))

    method create_process args new_stdin new_stdout new_stderr =
      match spawn_handler with
      | None -> raise (Would_spawn (true, None, args))
      | Some handler -> handler args new_stdin new_stdout new_stderr

    method set_spawn_handler handler =
      spawn_handler <- handler

    method reap_child = real_system#reap_child

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
        os = "Linux";
        release = "3.10.3-1-ARCH";
        machine = "x86_64";
      }

    method add_file path redirect_target =
      extra_files := StringMap.add path (File (0o644, redirect_target)) !extra_files;
      let rec add_parent path =
        let parent = Filename.dirname path in
        if (parent <> path) then (
          let leaf = Filename.basename path in
          let () =
            try
              match StringMap.find parent !extra_files with
              | Dir (mode, items) -> extra_files := StringMap.add parent (Dir (mode, leaf :: items)) !extra_files
              | _ -> failwith parent
            with Not_found ->
              self#add_dir parent [leaf] in
          add_parent parent
        ) in
      add_parent path

    method add_dir path items =
      extra_files := StringMap.add path (Dir (0o755, items)) !extra_files;
      let add_file leaf =
        let full = path +/ leaf in
        if not (StringMap.mem full !extra_files) then
          self#add_file full "" in
      List.iter add_file items

    initializer
      match tmpdir with
      | Some dir -> self#putenv "ZEROINSTALL_PORTABLE_BASE" dir
      | None -> ()
  end
;;

let forward_to_real_log = ref true
let real_log = !Support.Logging.handler
let () = Support.Logging.threshold := Support.Logging.Debug

let fake_log =
  object (_ : #Support.Logging.handler)
    val mutable record = []

    method reset () =
      record <- []

    method get () =
      record

    method dump () =
      if record = [] then
        print_endline "(log empty)"
      else (
        prerr_endline "(showing full log)";
        let dump (ex, level, msg) =
          real_log#handle ?ex level msg in
        List.iter dump @@ List.rev record;
      )

    method handle ?ex level msg =
      if !forward_to_real_log && level > Support.Logging.Info then real_log#handle ?ex level msg;
      if false then print_endline @@ "LOG: " ^ msg;
      record <- (ex, level, msg) :: record
  end

let () = Support.Logging.handler := (fake_log :> Support.Logging.handler)

let collect_logging fn =
  forward_to_real_log := false;
  Support.Utils.finally (fun () -> forward_to_real_log := true) () fn

let format_list l = "[" ^ (String.concat "; " l) ^ "]"
let equal_str_lists = assert_equal ~printer:format_list
let assert_str_equal = assert_equal ~printer:(fun x -> x)

let assert_raises_safe expected_msg fn =
  try Lazy.force fn; assert_failure ("Expected Safe_exception " ^ expected_msg)
  with Safe_exception (msg, _) ->
    assert_equal expected_msg msg

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
  Zeroinstall.Python.slave_debug_level := Some Support.Logging.Warning;
  let system = new fake_system tmpdir in
  if tmpdir = None then system#putenv "HOME" "/home/testuser";
  if on_windows then (
    system#putenv "PATH" "C:\\Windows\\system32;C:\\Windows";
    system#add_file (src_dir +/ "0install-runenv.exe") (build_dir +/ "0install-runenv.exe");
    system#add_file (src_dir +/ "0launch") (src_dir +/ "0launch")
  ) else (
    system#putenv "PATH" "/usr/bin:/bin"
  );
  (Config.get_default_config (system :> system) test_0install, system)
