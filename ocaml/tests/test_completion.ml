(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit
open Zeroinstall.General
open Support.Common
open Fake_system

let assert_contains expected actual =
  try
    ignore @@ Str.search_forward (Str.regexp_string expected) actual 0
  with Not_found ->
    assert_failure (Printf.sprintf "Expected substring '%s' not found in '%s'" expected actual)

let assert_not_contains not_expected actual =
  try
    ignore @@ Str.search_forward (Str.regexp_string not_expected) actual 0;
    assert_failure (Printf.sprintf "Unexpected substring '%s' found in '%s'" not_expected actual)
  with Not_found -> ()

let suite =
  "completion">:: with_tmpdir (fun tmpdir ->
    let config, system = get_fake_config (Some tmpdir) in
    let complete_with shell args cword =
      let cword = if shell = "zsh" then cword + 1 else cword in
      system#putenv "COMP_CWORD" @@ string_of_int cword;
      system#set_argv @@ Array.of_list ("0install" :: "_complete" :: shell :: "0install" :: args);
      system#collect_output @@ fun () -> Main.start (system :> system)
    in
    ListLabels.iter ["bash"; "zsh"; "fish"] ~f:(fun shell ->
      let complete = complete_with shell in
      if shell <> "bash" then (
        assert_contains "select\n" @@ complete ["s"] 1;

        assert_contains "select\n" @@ complete ["s"] 1;
        assert_contains "select\n" @@ complete [] 1;
        assert_contains "select\n" @@ complete [""; "bar"] 1;

        assert_str_equal "" @@ complete [""; "bar"] 2;
        assert_str_equal "" @@ complete ["unknown"; "bar"] 2;
        (* self.assertEqual("", complete(["--"; "s"] 2)) *)

        assert_contains "--help\n" @@ complete ["-"] 1;
        assert_contains "--help\n" @@ complete ["--"] 1;
        assert_contains "--help\n" @@ complete ["--h"] 1;
        assert_contains "-h\n" @@ complete ["-h"] 1;
        assert_contains "-hv\n" @@ complete ["-hv"] 1;
        assert_str_equal "" @@ complete ["-hi"] 1;

        (* assert "--message" not in complete(["--m"] 1) *)
        assert_contains "--message" @@ complete ["--m"; "select"] 1;
        assert_contains "--message" @@ complete ["select"; "--m"] 2;

        assert_contains "--help" @@ complete ["select"; "foo"; "--h"] 3;
        assert_not_contains "--help" @@ complete ["run"; "foo"; "--h"] 3;
        (* assert "--help" not in complete(["select"; "--version"; "--h"] 3) *)

        (* Fall back to file completion for the program's arguments *)
        assert_str_equal "file\n" @@ complete ["run"; "foo"; ""] 3;

        (* Option value completion *)
        assert_contains "file\n" @@ complete ["select"; "--with-store"] 3;
        assert_contains "Linux\n" @@ complete ["select"; "--os"] 3;
        assert_contains "x86_64\n" @@ complete ["select"; "--cpu"] 3;
        assert_contains "sha256new\n" @@ complete ["digest"; "--algorithm"] 3;
      );

      (* Option=value complete *)
      if shell <> "bash" then (
        assert_contains "file\n" @@ complete ["select"; "--with-store="] 2;
        assert_contains "add --cpu=x86_64\n" @@ complete ["select"; "--cpu="] 2;
      ) else (
        assert_contains "file\n" @@ complete ["select"; "--with-store"; "="] 3;
        assert_contains "file\n" @@ complete ["select"; "--with-store"; "="; "foo"] 4;
        assert_contains "add x86_64 \n" @@ complete ["select"; "--cpu"; "="] 3;
      );

      let write ch =
        output_string ch (
          "<?xml version='1.0'?>" ^
          "<interface uri='http://example.com/foo' xmlns='http://zero-install.sourceforge.net/2004/injector/interface'>" ^
          "<name>-</name><summary>-</summary>" ^
          "<implementation version='1.2' id='12'/>" ^
          "<implementation version='1.11' id='15' main='foo'/>" ^
          "</interface>"
        ) in
      let interfaces_dir =
        Support.Basedir.save_path (config.system) "0install.net/interfaces" config.basedirs.Support.Basedir.cache in
      let example_cached_path = interfaces_dir +/ "http%3a%2f%2fexample.com%2ffoo" in
      system#atomic_write [Open_wronly; Open_binary] write example_cached_path 0o644;

      if shell = "bash" then (
        assert_contains "add select \n" @@ complete ["sel"] 1;
        assert_str_equal "prefix http://example.com/\nfile\n" @@ complete ["select"; "ht"] 2;
        assert_str_equal "prefix //example.com/\nfile\n" @@ complete ["select"; "http:"] 2;
        assert_str_equal "prefix //example.com/\nfile\n" @@ complete ["select"; "http:/"] 2;
        assert_str_equal "add //example.com/foo \n" @@ complete ["select"; "http://example.com/"] 2;
      ) else (
        (* Check options are ignored correctly *)
        assert_str_equal "prefix http://example.com/\nfile\n" @@ complete ["select"; "--with-store=."; "http:"] 3;
        assert_str_equal "prefix http://example.com/\nfile\n" @@ complete ["select"; "http:"; "--with-store=."] 2;

        assert_str_equal "prefix http://example.com/\nfile\n" @@ complete ["select"; "--with-store"; "."; "http:"] 4;
        assert_str_equal "prefix http://example.com/\nfile\n" @@ complete ["select"; "http:"; "--with-store"; "."] 2;

        (* Version completion *)
        assert_str_equal "add 1.2\nadd 1.11\n" @@ complete ["select"; "--before"; ""; "http://example.com/foo"] 3;
        assert_str_equal "add 1.2\nadd 1.11\n" @@ complete ["select"; "--version"; ""; "http://example.com/foo"] 3;
        assert_str_equal "add 1.2..!1.2\nadd 1.2..!1.11\n" @@ complete ["select"; "--version"; "1.2.."; "http://example.com/foo"] 3;

        assert_str_equal "prefix http://example.com/\nfile\n" @@ complete ["select"; "--version-for"; "http:"; ""; ] 3;
        assert_str_equal "add 1.2\nadd 1.11\n" @@ complete ["select"; "--version-for"; "http://example.com/foo"; ""; ] 4;

        (* -- before argument *)
        assert_str_equal "prefix http://example.com/\nfile\n" @@ complete ["select"; "--"; "http:"] 3;
      );

      if shell = "zsh" then (
        assert_contains "--xml" @@ complete ["show"; "-"] 2;
        assert_contains "file\n" @@ complete ["show"; ""] 2;

        assert_contains "file\n" @@ complete ["download"; ""] 2;
        assert_contains "file\n" @@ complete ["update"; ""] 2;

        assert_contains "network_use" @@ complete ["config"] 2;
        assert_contains "full" @@ complete ["config"; "network_use"] 3;
        assert_contains "true" @@ complete ["config"; "help_with_testing"] 3;
        assert_contains "add 30d" @@ complete ["config"; "freshness"] 3;

        assert_str_equal "" @@ complete ["config"; "missing"] 3;
        assert_str_equal "" @@ complete ["config"; "network_use"; ""] 4;
        assert_str_equal "" @@ complete ["list-feeds"] 2;

        assert_contains "file\n" @@ complete ["run"; ""] 2;
        assert_contains "file\n" @@ complete ["digest"] 2;
        assert_str_equal ""      @@ complete ["add"; ""] 2;
        assert_contains "file\n" @@ complete ["add"; "foo"] 3;

        assert_contains "file\n" @@ complete ["import"; ""] 2;
        assert_contains "file\n" @@ complete ["add-feed"; ""] 2;
      );
    )
  )
