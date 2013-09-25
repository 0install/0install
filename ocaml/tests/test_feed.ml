(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
open Zeroinstall

module Q = Support.Qdom
module U = Support.Utils

let suite = "feed">::: [
  "langs">:: (fun () ->
    let (_config, fake_system) = Fake_system.get_fake_config None in
    let system = (fake_system :> system) in
    let local_path = Test_0install.feed_dir +/ "Local.xml" in
    let root = Q.parse_file system local_path in
    let feed = Feed.parse system root (Some local_path) in

    let () =
      let langs = Support.Locale.score_langs @@ U.filter_map ~f:Support.Locale.parse_lang ["en_US"; "en_GB"; "fr"] in
      assert_equal 6 (Support.Locale.score_lang langs @@ Some "en_US");
      assert_equal 4 (Support.Locale.score_lang langs @@ Some "en_GB");
      assert_equal 3 (Support.Locale.score_lang langs @@ Some "en");
      assert_equal 1 (Support.Locale.score_lang langs @@ Some "fr");
      assert_equal 0 (Support.Locale.score_lang langs @@ Some "gr");
      assert_equal 3 (Support.Locale.score_lang langs @@ None) in

    let test expected langs =
      let langs = Support.Locale.score_langs @@ U.filter_map ~f:Support.Locale.parse_lang langs in
      Fake_system.assert_str_equal expected @@ Fake_system.expect @@ Feed.get_summary langs feed in

    test "Local feed (English GB)" ["en_GB.UTF-8"];
    test "Local feed (English)" ["en_US"];
    test "Local feed (Greek)" ["gr"];
    test "Fuente local" ["es_PT"];
    test "Local feed (English GB)" ["en_US"; "en_GB"; "es"];
    test "Local feed (English)" ["en_US"; "es"];
  );
]
