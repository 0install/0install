(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* Testing the "0install" command-line interface *)

open Zeroinstall.General
open Support.Common
open OUnit
module Q = Support.Qdom
module U = Support.Utils
module R = Zeroinstall.Requirements
module Escape = Zeroinstall.Escape

let test_0install = Fake_system.test_0install

let assert_contains expected whole =
  try ignore @@ Str.search_forward (Str.regexp_string expected) whole 0
  with Not_found -> assert_failure (Printf.sprintf "Expected string '%s' not found in '%s'" expected whole)

let expect = function
  | None -> assert_failure "Unexpected None!"
  | Some x -> x

class fake_slave config =
  let pending_feed_downloads = ref StringMap.empty in
  let pending_digests = ref StringSet.empty in
  let system = config.system in

  let cache_path_for url =
    let cache = config.basedirs.Support.Basedir.cache in
    let dir = Support.Basedir.save_path system (config_site +/ "interfaces") cache in
    dir +/ Escape.escape url in

  let handle_import_feed url =
    let contents =
      try StringMap.find url !pending_feed_downloads
      with Not_found -> assert_failure url in
    pending_feed_downloads := StringMap.remove url !pending_feed_downloads;
    let target = cache_path_for url in
    let write ch = output_string ch contents in
    system#atomic_write [Open_wronly; Open_binary] write target 0o644;
    `List [`String "ok"; `List []] in

  let handle_download_selections xml =
    ListLabels.iter xml.Q.child_nodes ~f:(fun sel ->
      let open Zeroinstall.Selections in
      match make_selection sel with
      | CacheSelection digests ->
          if Zeroinstall.Stores.lookup_maybe system digests config.stores = None then (
            let digest_str =
              U.first_match digests ~f:(fun digest ->
                let digest_str = Zeroinstall.Stores.format_digest digest in
                if StringSet.mem digest_str !pending_digests then Some digest_str else None
              ) in
            match digest_str with
            | None -> raise_safe "Digest not expected!"
            | Some digest_str ->
                pending_digests := StringSet.remove digest_str !pending_digests;
                let user_store = List.hd config.stores in
                U.makedirs system (user_store +/ digest_str) 0o755;
                log_info "Added %s to stores" digest_str
          )
      | _ -> ()
    );
    `List [`String "ok"; `List []] in

  let fake_slave ?xml request =
    match request with
    | `List [`String "download-and-import-feed"; `String url] -> Some (Lwt.return @@ handle_import_feed url)
    | `List [`String "download-selections"; _opts] -> Some (Lwt.return @@ handle_download_selections (expect xml))
    | _ -> None in

  object
    method install =
      Zeroinstall.Python.slave_interceptor := fake_slave

    method allow_feed_download url contents =
      pending_feed_downloads := StringMap.add url contents !pending_feed_downloads

    method allow_download (hash:string) =
      pending_digests := StringSet.add hash !pending_digests
  end

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
    fake_system#set_argv [| test_0install; "-cor"; "download"; "http://example.com/prog.xml"; "--version"; "2" |];
    let () =
      try Main.main system; assert false
      with Safe_exception (msg, _) ->
        Fake_system.assert_str_equal (
          "Can't find all required implementations:\n" ^
          "- http://example.com/prog.xml -> (problem)\n" ^
          "    User requested version 2\n" ^
          "    No usable implementations:\n" ^
          "      sha1=3ce644dc725f1d21cfcf02562c76f375944b266a (1): Excluded by user-provided restriction: version 2\n" ^
          "Note: 0install is in off-line mode") msg in
    ()
  );

  "update">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let system = (fake_system :> system) in
    fake_system#add_file "/lib/ld-linux.so.2" "/";    (* Enable multi-arch *)

    let run ?(exit=0) args =
      fake_system#set_argv @@ Array.of_list (test_0install :: "--console" :: args);
      fake_system#collect_output (fun () ->
        try Main.main system; assert (exit = 0)
        with System_exit n -> assert_equal ~msg:"exit code" n exit
      ) in

    Unix.putenv "DISPLAY" "";

    let out = run ~exit:1 ["update"] in
    assert (U.starts_with out "Usage:");
    assert_contains "--message" out;

    (* Updating a local feed with no dependencies *)
    let local_file = tmpdir +/ "Local.xml" in
    U.copy_file system (".." +/ ".." +/ "tests" +/ "Local.xml") local_file 0o644;
    let out = run ["update"; local_file] in
    assert_contains "No updates found" out;

    let fake_slave = new fake_slave config in
    fake_slave#install;

    let feed_dir = ".." +/ ".." +/ "tests" in
    let binary_feed = Support.Utils.read_file system (feed_dir +/ "Binary.xml") in

    (* Using a remote feed for the first time *)
    fake_slave#allow_download "sha1=123";
    fake_slave#allow_feed_download "http://foo/Binary.xml" binary_feed;
    let out = run ["update"; "http://foo/Binary.xml"] in
    assert_contains "Binary.xml: new -> 1.0" out;

    (* No updates. *)
    (* todo: fails to notice that the binary is missing... *)
    fake_slave#allow_feed_download "http://foo/Binary.xml" binary_feed;
    let out = run ["update"; "http://foo/Binary.xml"] in
    assert_contains "No updates found" out;

    (* New binary release available. *)
    let new_binary_feed = Str.replace_first (Str.regexp_string "version='1.0'") "version='1.1'" binary_feed in
    assert (binary_feed <> new_binary_feed);
    fake_slave#allow_feed_download "http://foo/Binary.xml" new_binary_feed;
    let out = run ["update"; "http://foo/Binary.xml"] in
    assert_contains "Binary.xml: 1.0 -> 1.1" out;

    (* Compiling from source for the first time. *)
    let source_feed = U.read_file system (feed_dir +/ "Source.xml") in
    let compiler_feed = U.read_file system (feed_dir +/ "Compiler.xml") in
    fake_slave#allow_download "sha1=234";
    fake_slave#allow_download "sha1=345";
    fake_slave#allow_feed_download "http://foo/Compiler.xml" compiler_feed;
    fake_slave#allow_feed_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_feed_download "http://foo/Source.xml" source_feed;
    let out = run ["update"; "http://foo/Binary.xml"; "--source"] in
    assert_contains "Binary.xml: new -> 1.0" out;
    assert_contains "Compiler.xml: new -> 1.0" out;

    (* New compiler released. *)
    let new_compiler_feed = Str.replace_first (Str.regexp_string "id='sha1=345' version='1.0'") "id='sha1=345' version='1.1'" compiler_feed in
    assert (new_compiler_feed <> compiler_feed);
    fake_slave#allow_feed_download "http://foo/Compiler.xml" new_compiler_feed;
    fake_slave#allow_feed_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_feed_download "http://foo/Source.xml" source_feed;
    let out = run ["update"; "http://foo/Binary.xml"; "--source"] in
    assert_contains "Compiler.xml: 1.0 -> 1.1" out;

    (* A dependency disappears. *)
    let new_source_feed = U.read_file system (feed_dir +/ "Source-missing-req.xml") in
    fake_slave#allow_feed_download "http://foo/Compiler.xml" new_compiler_feed;
    fake_slave#allow_feed_download "http://foo/Binary.xml" binary_feed;
    fake_slave#allow_feed_download "http://foo/Source.xml" new_source_feed;
    let out = run ["update"; "http://foo/Binary.xml"; "--source"] in
    assert_contains "No longer used: http://foo/Compiler.xml" out;
  );
]
