(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* Testing the "0install" command-line interface *)

open Support.Common
open OUnit
module U = Support.Utils

let test_0install = Fake_system.test_0install

let suite = "0install">::: [
  "select">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (_config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    fake_system#add_file (tmpdir +/ "cache" +/ "0install.net" +/ "interfaces" +/ "http%3a%2f%2fexample.com%2fprog.xml") (".." +/ ".." +/ "tests" +/ "Hello.xml");
    fake_system#add_dir (tmpdir +/ "cache" +/ "0install.net" +/ "implementations") ["sha1=3ce644dc725f1d21cfcf02562c76f375944b266a"];
    fake_system#add_file "/lib/ld-linux.so.2" "/";    (* Enable multi-arch *)

    (* In --offline mode we select from the cached feed *)
    fake_system#set_argv [| test_0install; "-o"; "select"; "http://example.com/prog.xml" |];
    let output = fake_system#collect_output (fun () -> Main.main system) in
    assert (U.starts_with output "- URI: http://example.com/prog.xml");

    (* In online mode, we spawn a background process because we don't have a last-checked timestamp *)
    fake_system#set_argv [| test_0install; "select"; "http://example.com/prog.xml" |];
    let () =
      try failwith @@ fake_system#collect_output (fun () -> Main.main system)
      with Fake_system.Would_spawn (_, _, args) ->
        Fake_system.equal_str_lists
          ["update"; "--console"; "-v"; "--command"; "run"; "http://example.com/prog.xml"]
          (List.tl args) in

    (* Download succeeds (does nothing, as it's already cached *)
    fake_system#set_argv [| test_0install; "-o"; "download"; "http://example.com/prog.xml" |];
    let output = fake_system#collect_output (fun () -> Main.main system) in
    Fake_system.assert_str_equal "" output;

    (* Use --console --offline --refresh to force us to use the Python *)
    let my_spawn_handler args cin cout cerr =
      Fake_system.real_system#create_process args cin cout cerr in
    fake_system#set_spawn_handler (Some my_spawn_handler);
    fake_system#set_argv [| test_0install; "-cor"; "download"; "http://example.com/prog.xml" |];
    let () =
      try Main.main system; assert false
      with Safe_exception (msg, _) ->
        Fake_system.assert_str_equal (
          "Can't find all required implementations:\n" ^
          "- http://example.com/prog.xml -> (problem)\n" ^
          "    No known implementations at all\n" ^
          "Note: 0install is in off-line mode") msg in
    ()
  )
]
