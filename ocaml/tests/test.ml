open OUnit
open General
open Support.Common

(* let () = Support.Logging.threshold := Support.Logging.Info *)

class fake_system =
  object (_ : #system)
    val now = ref 0.0
    val mutable env = StringMap.empty

    val files = Hashtbl.create 10

    method time () = !now

    method with_open = failwith "file access"
    method mkdir = failwith "file access"
    method readdir = failwith "file access"
    method chmod = failwith "file access"

    method file_exists path =
      log_info "Check whether file %s exists" path;
      Hashtbl.mem files path

    method lstat = failwith "file access"
    method stat = failwith "file access"
    method atomic_write = failwith "file access"
    method unlink = failwith "file access"
    method rmdir = failwith "file access"

    method exec = failwith "exec"
    method create_process = failwith "exec"
    method reap_child = failwith "reap_child"

    method getcwd = failwith "getcwd"

    method getenv name =
      try Some (StringMap.find name env)
      with Not_found -> None

    method putenv name value =
      env <- StringMap.add name value env
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
      record <- (ex, level, msg) :: record
  end

let () = Support.Logging.handler := (fake_log :> Support.Logging.handler)

let format_list l = "[" ^ (String.concat "; " l) ^ "]"
let equal_str_lists = assert_equal ~printer:format_list
let assert_str_equal = assert_equal ~printer:(fun x -> x)

let real_system = new Support.System.real_system

let () = Random.self_init ()
let with_tmpdir fn () =
  let tmppath = Filename.get_temp_dir_name () +/ Printf.sprintf "0install-test-%x" (Random.int 0x3fffffff) in
  Unix.mkdir tmppath 0o700;   (* will fail if already exists; OK for testing *)
  Support.Utils.finally (Support.Utils.ro_rmtree real_system) tmppath fn

let test_basedir () =
  skip_if (Sys.os_type = "Win32") "Don't work on Windows";

  let system = new fake_system in
  let open Support.Basedir in

  let bd = get_default_config (system :> system) in
  equal_str_lists ~msg:"No $HOME1" ["/root/.config"; "/etc/xdg"] bd.config;
  equal_str_lists ~msg:"No $HOME2" ["/root/.cache"; "/var/cache"] bd.cache;
  equal_str_lists ~msg:"No $HOME3" ["/root/.local/share"; "/usr/local/share"; "/usr/share"] bd.data;

  system#putenv "HOME" "/home/bob";
  let bd = get_default_config (system :> system) in
  equal_str_lists ~msg:"$HOME1" ["/home/bob/.config"; "/etc/xdg"] bd.config;
  equal_str_lists ~msg:"$HOME2" ["/home/bob/.cache"; "/var/cache"] bd.cache;
  equal_str_lists ~msg:"$HOME3" ["/home/bob/.local/share"; "/usr/local/share"; "/usr/share"] bd.data;

  system#putenv "XDG_CONFIG_HOME" "/home/bob/prefs";
  system#putenv "XDG_CACHE_DIRS" "";
  system#putenv "XDG_DATA_DIRS" "/data1:/data2";
  let bd = get_default_config (system :> system) in
  equal_str_lists ~msg:"XDG1" ["/home/bob/prefs"; "/etc/xdg"] bd.config;
  equal_str_lists ~msg:"XDG2" ["/home/bob/.cache"] bd.cache;
  equal_str_lists ~msg:"XDG3" ["/home/bob/.local/share"; "/data1"; "/data2"] bd.data;

  system#putenv "ZEROINSTALL_PORTABLE_BASE" "/mnt/0install";
  let bd = get_default_config (system :> system) in
  equal_str_lists ~msg:"PORT-1" ["/mnt/0install/config"] bd.config;
  equal_str_lists ~msg:"PORT-2" ["/mnt/0install/cache"] bd.cache;
  equal_str_lists ~msg:"PORT-3" ["/mnt/0install/data"] bd.data;
;; 

let assert_raises_safe expected_msg fn =
  try Lazy.force fn; assert_failure ("Expected Safe_exception " ^ expected_msg)
  with Safe_exception (msg, _) ->
    assert_equal expected_msg msg

let assert_raises_fallback fn =
  try Lazy.force fn; assert_failure "Expected Fallback_to_Python"
  with Fallback_to_Python -> ()

let get_fake_config () =
  let system = (new fake_system :> system) in
  let my_path =
    if on_windows then "C:\\Windows\\system32"
    else "/usr/bin/0install" in
  Config.get_default_config system my_path

let test_option_parsing () =
  let config = get_fake_config () in
  let open Options in
  let p args = Cli.parse_args config args in

  assert_equal Maybe (p []).gui;
  assert_equal No (p ["--console"]).gui;

  let s = p ["--with-store"; "/data/store"; "run"; "foo"] in
  assert_equal "/data/store" (List.hd config.stores);
  equal_str_lists ["run"; "foo"] s.args;

  config.stores <- [];
  let s = p ["--with-store=/data/s1"; "run"; "--with-store=/data/s2"; "foo"; "--with-store=/data/s3"] in
  equal_str_lists ["/data/s2"; "/data/s1"] config.stores;
  equal_str_lists ["run"; "foo"; "--with-store=/data/s3"] s.args;

  assert_raises_safe "Option does not take an argument in '--console=true'" (lazy (p ["--console=true"]));

  assert (List.length (fake_log#get ()) = 0);
  let s = p ["-cvv"] in
  assert_equal No s.gui;
  assert_equal 2 s.verbosity;
  assert (List.length (fake_log#get ()) > 0);

  let s = p ["run"; "-wgdb"; "foo"] in
  equal_str_lists ["run"; "foo"] s.args;
  assert_equal [("-w", Wrapper "gdb")] s.extra_options;

  assert_raises_fallback (lazy (p ["-c"; "--version"]));

  let s = p ["--version"; "1.2"; "run"; "foo"] in
  equal_str_lists ["run"; "foo"] s.args;
  assert_equal [("--version", RequireVersion "1.2")] s.extra_options;
;;

let test_run_real tmpdir =
  Unix.putenv "ZEROINSTALL_PORTABLE_BASE" tmpdir;
  let checked_close_process_in ch =
    if Unix.close_process_in ch <> Unix.WEXITED 0 then
      assert_failure "Child process failed" in
  let test_command =
    if on_windows then "..\\_build\\0install run .\\test_selections_win.xml"
    else"../_build/0install run ./test_selections.xml" in
  let line =
    Support.Utils.finally checked_close_process_in
      (Unix.open_process_in test_command) (fun ch ->
      input_line ch
  ) in
  assert_str_equal "Hello World" line
;;

let test_windows_escaping () =
  assert_str_equal "\\\\"                       @@ Run.windows_args_escape ["\\"];
  assert_str_equal "foo bar"                  @@ Run.windows_args_escape ["foo"; "bar"];
  assert_str_equal "\"foo bar\""              @@ Run.windows_args_escape ["foo bar"];
  assert_str_equal "\"foo \\\"bar\\\"\""      @@ Run.windows_args_escape ["foo \"bar\""];
  assert_str_equal "\"foo \\\\\\\"bar\\\"\""  @@ Run.windows_args_escape ["foo \\\"bar\""]

(* Name the test cases and group them together *)
let suite = 
"0install">:::[
 "test_basedir">:: test_basedir;
 "test_option_parsing">:: test_option_parsing;
 "test_run_real">:: with_tmpdir test_run_real;
 "test_windows_escaping">:: test_windows_escaping;
];;

let () = Printexc.record_backtrace true;;

let _ = run_test_tt_main suite;;

Format.print_newline ()
