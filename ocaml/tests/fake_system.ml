(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit
open Zeroinstall.General
open Support.Common
module Config = Zeroinstall.Config
module U = Support.Utils

let orig_packagekit = !Zeroinstall.Packagekit.packagekit

let () =
  (* Make oUnit 2 happy: we need to be able to reset these to their initial values after each test. *)
  Unix.putenv "ZEROINSTALL_PORTABLE_BASE" "/UNUSED";
  Unix.putenv "DISPLAY" "";
  Unix.putenv "DBUS_SESSION_BUS_ADDRESS" "UNUSED";
  Unix.putenv "DBUS_SYSTEM_BUS_ADDRESS" "UNUSED";
  Unix.putenv "GNUPGHOME" "/UNUSED"

(* For temporary directory names *)
let () = Random.self_init ()

(* let () = Support.Logging.threshold := Support.Logging.Info *)

type mode = int

type dentry =
  | Dir of (mode * string list)
  | File of (mode * filepath)

let expect = function
  | Some x -> x
  | None -> assert_failure "got None!"

module RealSystem = Support.System.RealSystem(Unix)
let real_system = new RealSystem.real_system

let build_dir = Filename.dirname @@ Filename.dirname Sys.argv.(0)

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

let flush_all () =
  Pervasives.flush Pervasives.stdout;
  Pervasives.flush Pervasives.stderr

let capture_stdout ?(include_stderr=false) fn =
  let open Unix in
  U.finally_do
    (fun (old_stdout, old_stderr) ->
      dup2 old_stdout Unix.stdout; close old_stdout;
      dup2 old_stderr Unix.stderr; close old_stderr)
    (dup Unix.stdout, dup Unix.stderr)
    (fun _old ->
      let tmp = Filename.temp_file "0install-" "-test-output" in
      U.finally_do
        (fun fd -> flush_all (); close fd; unlink tmp)
        (openfile tmp [O_RDWR] 0o600)
        (fun tmpfd ->
          dup2 tmpfd Unix.stdout;
          if include_stderr then dup2 tmpfd Unix.stderr;
          fn ();
          flush_all ();
          U.read_file real_system tmp
        )
    )

exception Would_exec of (bool * string array option * string list)
exception Would_spawn of (bool * string array option * string list)

let ocaml_dir = Sys.getcwd ()
let src_dir = Filename.dirname ocaml_dir
let tests_dir = ocaml_dir +/ "tests"
let test_0install = src_dir +/ "0install"           (* Pretend we're running from here so we find 0install-python-fallback *)

class fake_system tmpdir =
  let extra_files : dentry StringMap.t ref = ref StringMap.empty in
  let hidden_files = ref StringSet.empty in
  let redirect_writes = ref None in

  let read_ok = ref [] in   (* Always allow reading from these directories *)

  (* Prevent reading from $HOME, except for the code we're testing (to avoid accidents, e.g. reading user's config files).
   * Also, apply any redirections in extra_files. *)
  let check_read path =
    (* log_info "check_read(%s)" path; *)
    if Filename.is_relative path then path
    else (
      try
        match StringMap.find path !extra_files with
        | Dir _ -> path
        | File (_mode, redirect_path) -> redirect_path
      with Not_found ->
        if not (U.starts_with path "/home") then path
        else if U.starts_with path src_dir then path
        else (
          if !read_ok |> List.exists (fun dir ->
            U.starts_with path dir || U.starts_with dir path) then path
          else raise_safe "Attempt to read from '%s'" path
        )
    ) in

  let check_write path =
    match !redirect_writes with
    | Some (from, target) when U.starts_with path from ->
        target +/ (U.string_tail path (String.length from))
    | _ ->
        match tmpdir with
        | Some dir when U.starts_with path dir -> path
        | Some dir -> raise_safe "Attempt to write to %s (not in %s)" path dir
        | None -> raise_safe "Attempt to write to '%s' (no tmpdir)" path in

  (* It's OK to check whether these paths exists. We just say they don't,
     unless they're in extra_files (check there first). *)
  let hidden_subtree path =
    if U.starts_with path "/var" then
      match tmpdir with
      | None -> true
      | Some tmpdir -> not (U.starts_with (U.realpath real_system path) tmpdir)
    else false in

  object (self : #system)
    val now = ref @@ float_of_int @@ 101 * days
    val mutable env = StringMap.empty
    val mutable stdout = None
    val mutable spawn_handler = None
    val mutable allow_spawn_detach = false
    val mutable device_boundary = None    (* Reject renames across here to simulate a mount *)

    method collect_output (fn : unit -> unit) =
      let old_stdout = stdout in
      let b = Buffer.create 100 in
      stdout <- Some b;
      U.finally_do (fun () -> stdout <- old_stdout) () fn;
      Buffer.contents b

    method print_string s =
      match stdout with
      | None -> real_system#print_string s
      | Some b -> Buffer.add_string b s

    val mutable argv = [| test_0install |]

    method argv = argv
    method isatty _ = false
    method set_argv new_argv = argv <- new_argv

    method time = !now
    method set_time t = now := t

    method set_mtime path mtime = real_system#set_mtime (check_write path) mtime

    method with_open_in flags mode path fn = real_system#with_open_in flags mode (check_read path) fn
    method with_open_out flags mode path fn = real_system#with_open_out flags mode (check_write path) fn

    method mkdir path mode = real_system#mkdir (check_write path) mode

    method rename source target =
      device_boundary |> if_some (fun device_boundary ->
        let a_dev = U.starts_with source device_boundary in
        let b_dev = U.starts_with target device_boundary in
        if a_dev <> b_dev then
          raise (Unix.Unix_error (Unix.EXDEV, "rename", target))
      );
      real_system#rename (check_write source) (check_write target)

    method set_device_boundary b = device_boundary <- b

    method readdir path =
      try
        match StringMap.find path !extra_files with
        | Dir (_mode, items) -> Success (Array.of_list items)
        | _ -> failwith "Not a directory"
      with Not_found -> real_system#readdir (check_read path)

    method symlink ~target ~newlink = real_system#symlink ~target ~newlink:(check_write newlink)

    method readlink path =
      if StringMap.mem path !extra_files then None    (* Not a link *)
      else real_system#readlink (check_read path)

    method chmod path mode = real_system#chmod (check_write path) mode

    method file_exists path =
      if path = "/usr/bin/0install" then true
      else if path = "C:\\Windows\\system32\\0install.exe" then true
      else if StringMap.mem path !extra_files then true
      else if StringSet.mem path !hidden_files then (log_info "hide %s" path; false)
      else if tmpdir = None then false
      else real_system#file_exists (check_read path)

    method lstat path =
      if StringSet.mem path !hidden_files then None
      else (
        try
          let open Unix in
          match StringMap.find path !extra_files with
          | Dir (mode, _items) -> Some (make_stat mode S_DIR)
          | File (_mode, target) -> real_system#lstat target
        with Not_found ->
          if hidden_subtree path then None
          else real_system#lstat (check_read path)
      )

    method stat path =
      if StringSet.mem path !hidden_files then None
      else (
        try
          let open Unix in
          match StringMap.find path !extra_files with
          | Dir (mode, _items) -> Some (make_stat mode S_DIR)
          | File (_mode, target) -> real_system#stat target
        with Not_found ->
          if hidden_subtree path then None
          else real_system#stat (check_read path)
      )

    method atomic_write open_flags path ~mode fn = real_system#atomic_write open_flags (check_write path) ~mode fn
    method hardlink orig copy = real_system#hardlink (check_write orig) (check_write copy)
    method unlink path = real_system#unlink (check_write path)
    method rmdir path = real_system#rmdir (check_write path)

    method exec ?(search_path = false) ?env argv =
      raise (Would_exec (search_path, env, argv))

    method allow_spawn_detach v = allow_spawn_detach <- v

    method spawn_detach ?(search_path = false) ?env argv =
      if allow_spawn_detach then (
        ignore search_path;
        (* For testing, we run in-process to allow tests interceptors to work, etc. *)
        if List.hd argv <> test_0install then failwith "spawn_detach";
        let config = Zeroinstall.Config.get_default_config (self :> system) test_0install in
        Cli.handle config (List.tl argv)
      ) else raise (Would_spawn (search_path, env, argv))

    method create_process ?env:_ args new_stdin new_stdout new_stderr =
      match spawn_handler with
      | None -> raise (Would_spawn (true, None, args))
      | Some handler -> handler args new_stdin new_stdout new_stderr

    method set_spawn_handler handler =
      spawn_handler <- handler

    method reap_child = real_system#reap_child
    method waitpid_non_intr = real_system#waitpid_non_intr

    method getcwd =
      match tmpdir with
      | None -> "/root"
      | Some _ -> real_system#getcwd

    method chdir path =
      real_system#chdir path

    method environment =
      let to_str (name, value) = name ^ "=" ^ value in
      Array.of_list (List.map to_str @@ StringMap.bindings env)

    method getenv name =
      try Some (StringMap.find name env)
      with Not_found -> None

    method putenv name value =
      env <- StringMap.add name value env

    method unsetenv name =
      env <- StringMap.remove name env

    method platform =
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

    (** Writes to src/foo become writes to target/foo *)
    method redirect_writes src target =
      redirect_writes := Some (src ^ Filename.dir_sep, target ^ Filename.dir_sep)

    method add_dir path items =
      extra_files := StringMap.add path (Dir (0o755, items)) !extra_files;
      let add_file leaf =
        let full = path +/ leaf in
        if not (StringMap.mem full !extra_files) then
          self#add_file full "" in
      List.iter add_file items

    method hide_path path =
      hidden_files := StringSet.add path !hidden_files

    method running_as_root = false

    method with_stdin : 'a. string -> ('a Lazy.t) -> 'a = fun msg fn ->
      let tmpfile = Filename.temp_file "0install-" "-test" in
      let tmp_fd = Unix.openfile tmpfile [Unix.O_RDWR] 0o644 in
      Unix.unlink tmpfile;

      ignore @@ Unix.write tmp_fd msg 0 (String.length msg);
      ignore @@ Unix.lseek tmp_fd 0 Unix.SEEK_SET;
      U.finally_do
        (fun old_stdin -> Unix.dup2 old_stdin Unix.stdin; Unix.close old_stdin)
        (Unix.dup Unix.stdin)
        (fun _old_stdin ->
          Unix.dup2 tmp_fd Unix.stdin;
          Unix.close tmp_fd;
          Lazy.force fn
        )

    method allow_read dir =
      read_ok := dir :: !read_ok

    initializer
      match tmpdir with
      | Some dir ->
          self#putenv "ZEROINSTALL_PORTABLE_BASE" dir;
          Unix.putenv "ZEROINSTALL_PORTABLE_BASE" dir   (* For sub-processes *)
      | None -> ()

    method bypass_dryrun = (self :> system)
  end

let forward_to_real_log = ref true
let real_log = !Support.Logging.handler
let () = Support.Logging.threshold := Support.Logging.Debug

class null_ui =
  object (_ : #Zeroinstall.Ui.ui_handler)
    method start_monitoring ~cancel:_ ~url:_ ~progress:_ ?hint:_ ~id:_ = Lwt.return ()
    method stop_monitoring _ = Lwt.return ()
    method confirm_keys feed_url _xml = raise_safe "confirm_keys: %s" (Zeroinstall.Feed_url.format_url feed_url)
    method confirm msg = raise_safe "confirm: %s" msg
    method use_gui = false
  end

let null_ui = lazy (new null_ui)

let make_driver ?slave ?fetcher config =
  let slave = slave |? lazy (new Zeroinstall.Python.slave config) in
  let distro = Zeroinstall.Distro.generic_distribution slave in
  let trust_db = new Zeroinstall.Trust.trust_db config in
  let downloader = new Zeroinstall.Downloader.downloader null_ui ~max_downloads_per_site:2 in
  let fetcher = fetcher |? lazy (new Zeroinstall.Fetch.fetcher config trust_db downloader distro null_ui) in
  new Zeroinstall.Driver.driver config fetcher distro null_ui slave

let fake_log =
  object (_ : #Support.Logging.handler)
    val mutable record = []

    method reset =
      record <- []

    method get =
      record

    method pop_warnings =
      let warnings = record |> U.filter_map (function
        | (_ex, Support.Logging.Warning, msg) -> Some msg
        | _ -> None) in
      record <- [];
      warnings

    method dump =
      if record = [] then
        print_endline "(log empty)"
      else (
        prerr_endline "(showing full log)";
        let dump (ex, level, msg) =
          real_log#handle ?ex level msg in
        List.iter dump @@ List.rev record;
      )

    method assert_contains expected =
      let re = Str.regexp expected in
      if not (List.exists (fun (_ex, _lvl, msg) -> Str.string_match re msg 0) record) then
        raise_safe "Expected log message matching '%s'" expected

    method handle ?ex level msg =
      if !forward_to_real_log && level > Support.Logging.Info then real_log#handle ?ex level msg;
      if false then prerr_endline @@ "LOG: " ^ msg;
      record <- (ex, level, msg) :: record
  end

let () = Support.Logging.handler := (fake_log :> Support.Logging.handler)

let collect_logging fn =
  forward_to_real_log := false;
  U.finally_do (fun () -> forward_to_real_log := true) () fn

let format_list l = "[" ^ (String.concat "; " l) ^ "]"
let equal_str_lists = assert_equal ~printer:format_list
let assert_str_equal = assert_equal ~printer:(fun x -> x)

let assert_raises_safe expected_msg (fn:unit Lazy.t) =
  try Lazy.force fn; assert_failure ("Expected Safe_exception " ^ expected_msg)
  with Safe_exception (msg, _) ->
    if not (Str.string_match (Str.regexp expected_msg) msg 0) then
      raise_safe "Error '%s' does not match regexp '%s'" msg expected_msg

let temp_dir_name =
  (* Filename.get_temp_dir_name doesn't exist under 3.12 *)
  U.realpath real_system
    begin try Sys.getenv "TEMP" with Not_found ->
      match Sys.os_type with
        | "Unix" | "Cygwin" -> "/tmp"
        | "Win32" -> "."
        | _ -> failwith "temp_dir_name: unknown filesystem" end

let with_tmpdir fn () =
  U.finally_do
    (fun () -> Unix.putenv "ZEROINSTALL_PORTABLE_BASE" "/UNUSED"; Unix.putenv "GNUPGHOME" "/UNUSED") ()
    (fun () ->
      let tmppath = U.make_tmp_dir real_system temp_dir_name ~prefix:"0install-test-" in
      U.finally_do (U.rmtree ~even_if_locked:true real_system) tmppath fn
    )

let get_fake_config tmpdir =
  Zeroinstall.Python.slave_debug_level := Some Support.Logging.Warning;
  Zeroinstall.Python.slave_interceptor := Zeroinstall.Python.default_interceptor;
  let system = new fake_system tmpdir in
  let home =
    match tmpdir with
    | None -> "/home/testuser";
    | Some dir ->
        Unix.putenv "GNUPGHOME" dir;
        system#allow_read dir;
        dir in
  system#putenv "HOME" home;
  if on_windows then (
    system#add_file (src_dir +/ "0install-runenv.exe") (build_dir +/ "0install-runenv.exe");
    system#add_file (src_dir +/ "0install-python-fallback") (src_dir +/ "0install-python-fallback");
    let python = expect @@ U.find_in_path real_system "python" in
    system#add_file python python;
    system#putenv "PATH" @@ Sys.getenv "PATH" ^ ";" ^ Filename.dirname python;
  ) else (
    system#putenv "PATH" @@ (home +/ "bin") ^ ":" ^ (Sys.getenv "PATH");
    system#add_file test_0install (build_dir +/ "0install");
  );
  (* Allow reading from all PATH directories *)
  Str.split_delim U.re_path_sep (system#getenv "PATH" |? lazy (failwith "PATH")) |> List.iter (fun dir ->
    system#allow_read dir
  );
  (Config.get_default_config (system :> system) test_0install, system)

let with_fake_config fn =
  with_tmpdir (fun tmpdir ->
    get_fake_config (Some tmpdir) |> fn
  )

let assert_contains expected whole =
  try ignore @@ Str.search_forward (Str.regexp_string expected) whole 0
  with Not_found -> assert_failure (Printf.sprintf "Expected string '%s' not found in '%s'" expected whole)

let assert_error_contains expected (fn:unit -> unit) =
  try
    fn ();
    assert_failure (Printf.sprintf "Expected error '%s' but got success!" expected)
  with Safe_exception (msg, _) ->
    assert_contains expected msg

let fake_packagekit _config =
  object
    method is_available = Lwt.return false
    method get_impls (package_name:string) : Zeroinstall.Packagekit.package_info list =
      log_info "packagekit: get_impls(%s)" package_name;
      []
    method check_for_candidates (package_names:string list) : unit Lwt.t =
      log_info "packagekit: check_for_candidates(%s)" (String.concat ", " package_names);
      Lwt.return ()
    method install_packages _ui _names = failwith "install_packages"
  end
