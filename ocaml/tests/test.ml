(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit
open Zeroinstall.General
open Support.Common
open Fake_system

(* let () = Support.Logging.threshold := Support.Logging.Info *)

let () = Unix.putenv "http_proxy" "localhost:1111"    (* Prevent accidents *)

let test_basedir () =
  skip_if (Sys.os_type = "Win32") "Don't work on Windows";

  let system = new fake_system None in
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

let test_option_parsing () =
  Support.Logging.threshold := Support.Logging.Warning;

  let config, fake_system = get_fake_config None in
  let open Options in

  let p_full raw_args =
    let (raw_options, args, complete) = Support.Argparse.read_args Cli.spec raw_args in
    assert (complete = Support.Argparse.CompleteNothing);
    let subcommand =
      match args with
      | command :: _ -> List.assoc command Cli.subcommands
      | [] -> Cli.no_command in
    let flags = Support.Argparse.parse_options subcommand#options raw_options in
    let options = Cli.get_default_options config in
    let process = function
      | #common_option as flag -> Common_options.process_common_option options flag
      | _ -> () in
    Support.Argparse.iter_options flags process;
    (options, flags, args) in

  let p args = let (options, _flags, _args) = p_full args in options in

  assert_equal Maybe (p ["select"]).gui;
  assert_equal No (p ["--console"; "select"]).gui;

  let _, _, args = p_full ["--with-store"; "/data/store"; "run"; "foo"] in
  assert_equal "/data/store" (List.nth config.stores @@ List.length config.stores - 1);
  equal_str_lists ["run"; "foo"] args;

  config.stores <- [];
  let _, _, args = p_full ["--with-store=/data/s1"; "run"; "--with-store=/data/s2"; "foo"; "--with-store=/data/s3"] in
  equal_str_lists ["/data/s1"; "/data/s2"] config.stores;
  equal_str_lists ["run"; "foo"; "--with-store=/data/s3"] args;

  assert_raises_safe "Option does not take an argument in '--console=true'" (lazy (p ["--console=true"]));

  assert (List.length (fake_log#get ()) = 0);
  let s = p ["-cvv"; "run"] in
  assert_equal No s.gui;
  assert_equal 2 s.verbosity;
  assert (List.length (fake_log#get ()) > 0);

  let _, flags, args = p_full ["run"; "-wgdb"; "foo"] in
  equal_str_lists ["run"; "foo"] args;
  assert_equal [("-w", `Wrapper "gdb")] flags;

  let v = fake_system#collect_output (fun () -> (
    try ignore @@ p ["-c"; "--version"]; assert false;
    with System_exit 0 -> ()
  ))
  in assert (Str.string_match (Str.regexp_string "0install (zero-install)") v 0);

  let _, flags, args = p_full ["--version"; "1.2"; "run"; "foo"] in
  equal_str_lists ["run"; "foo"] args;
  assert_equal [("--version", `RequireVersion "1.2")] flags;

  let _, flags, args = p_full ["digest"; "-m"; "archive.tgz"] in
  equal_str_lists ["digest"; "archive.tgz"] args;
  assert_equal [("-m", `ShowManifest)] flags;

  let _, flags, args = p_full ["run"; "-m"; "main"; "app"] in
  equal_str_lists ["run"; "app"] args;
  assert_equal [("-m", `MainExecutable "main")] flags;
;;

let test_run_real tmpdir =
  Unix.putenv "ZEROINSTALL_PORTABLE_BASE" tmpdir;
  let sels_path =
    if on_windows then ".\\test_selections_win.xml"
    else "./test_selections.xml" in
  let argv = [Fake_system.build_dir +/ "0install"; "run"; sels_path] in
  let line = Support.Utils.check_output real_system Support.Utils.input_all argv in
  assert_str_equal "Hello World\n" line

(* This is really just for the coverage testing, which test_run_real doesn't do. *)
let test_run_fake tmpdir =
  let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
  let sels_path = Support.Utils.abspath Fake_system.real_system (
    if on_windows then ".\\test_selections_win.xml"
    else "./test_selections.xml"
  ) in
  fake_system#add_file sels_path sels_path;
  try Cli.handle config ["run"; sels_path; "--"; "--arg"]; assert false
  with Fake_system.Would_exec (search, _env, args) ->
    assert (not search);
    if on_windows then equal_str_lists ["c:\\cygwin\\bin\\env.exe"; "my-prog"; "Hello World"; "--"; "--arg"] args
    else equal_str_lists ["/usr/bin/env"; "my-prog"; "Hello World"; "--"; "--arg"] args

let test_escaping () =
  let open Zeroinstall.Escape in
  let wfile s = if on_windows then "file%3a" ^ s else "file:" ^ s in
  List.iter (fun (a, b) -> assert_str_equal a b) [
    (* Escaping *)
    ("", escape "");
    ("hello", escape "hello");
    ("%20", escape " ");

    ("file%3a%2f%2ffoo%7ebar", escape "file://foo~bar");
    ("file%3a%2f%2ffoo%25bar", escape "file://foo%bar");

    (wfile "##foo%7ebar", pretty "file://foo~bar");
    (wfile "##foo%25bar", pretty "file://foo%bar");

    (* Unescaping *)
    ("", unescape "");
    ("hello", unescape "hello");
    (" ", unescape "%20");

    ("file://foo~bar", unescape "file%3a%2f%2ffoo%7ebar");
    ("file://foo%bar", unescape "file%3a%2f%2ffoo%25bar");

    ("file://foo", unescape "file:##foo");
    ("file://foo~bar", unescape "file:##foo%7ebar");
    ("file://foo%bar", unescape "file:##foo%25bar");
  ];

  assert_str_equal "http_3a_____example.com" @@ underscore_escape "http://example.com";
  assert_str_equal "_25_20_25_21_7e__26__21__22_£_20__3a__40__3b__2c_.___7b__7d__24__25__5e__26__28__29_" @@ underscore_escape "%20%21~&!\"£ :@;,./{}$%^&()";

  let check str =
    assert_str_equal str @@ unescape @@ escape str;
    assert_str_equal str @@ unescape @@ pretty str;
    assert_str_equal str @@ ununderscore_escape @@ underscore_escape str in

  check "";
  check "http://example.com";
  check "http://example%46com";
  check "http:##example#com";
  check "http://example.com/foo/bar.xml";
  check "%20%21~&!\"£ :@;,./{}$%^&()";
  check "http://example.com/foo_bar-50%á.xml";
  check "_one__two___three____four_____";
  check "_1_and_2_"

(* Name the test cases and group them together *)
let suite = 
"0install">:::[
  Test_completion.suite;
  Test_versions.suite;
  Test_utils.suite;
  Test_solver.suite;
  Test_distro.suite;
  Test_0install.suite;
  Test_apps.suite;
  Test_driver.suite;
 "test_basedir">:: test_basedir;
 "test_option_parsing">:: (fun () -> collect_logging test_option_parsing);
 "test_run_real">:: (fun () -> collect_logging (with_tmpdir test_run_real));
 "test_run_fake">:: (fun () -> collect_logging (with_tmpdir test_run_fake));
 "test_escaping">:: test_escaping;
 "test_canonical">:: (fun () ->
   let system = (new fake_system None :> system) in
   let check arg uri =
     assert_str_equal uri (Generic_select.canonical_iface_uri system arg) in
   let check_err arg =
     try (ignore @@ Generic_select.canonical_iface_uri system arg); assert false
     with Safe_exception _ -> () in
   check "http://example.com/foo.xml" "http://example.com/foo.xml";
   check "alias:./v1-alias" "http://example.com/alias1.xml";
   check "alias:./v2-alias" "http://example.com/alias2.xml";
   check_err "http://example.com";
 );
 "test_locale">:: (fun () ->
   let test expected vars =
     let system = new fake_system None in
     List.iter (fun (k, v) -> system#putenv k v) vars;
     equal_str_lists expected @@ List.map Support.Locale.format_lang @@ Support.Locale.get_langs (system :> system) in

   test ["en_GB"] [];
   test ["fr_FR"; "en_GB"] [("LANG", "fr_FR")];
   test ["en_GB"] [("LANG", "en_GB")];
   test ["de_DE"; "en_GB"] [("LANG", "de_DE@euro")];
   test ["en_GB"] [("LANGUAGE", "de_DE@euro:fr")];
   test ["de_DE"; "fr"; "en_GB"] [("LANG", "de_DE@euro"); ("LANGUAGE", "de_DE@euro:fr")];
   test ["de_DE"; "en_GB"] [("LANG", "fr_FR"); ("LC_ALL", "de_DE")];
   test ["de_DE"; "en_GB"] [("LANG", "fr_FR"); ("LC_MESSAGES", "de_DE")];
 );
];;

let show_log_on_failure fn () =
  try
    Fake_system.fake_log#reset ();
    fn ()
  with ex ->
    Fake_system.fake_log#dump ();
    raise ex

let () =
  Printexc.record_backtrace true;
  ignore @@ run_test_tt_main @@ test_decorate show_log_on_failure suite;
  Format.print_newline ()
