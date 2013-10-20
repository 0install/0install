(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
open Zeroinstall.General

module Q = Support.Qdom
module U = Support.Utils
module F = Zeroinstall.Feed

let suite = "feed">::: [
  "langs">:: (fun () ->
    let (_config, fake_system) = Fake_system.get_fake_config None in
    let system = (fake_system :> system) in
    let local_path = Test_0install.feed_dir +/ "Local.xml" in
    let root = Q.parse_file system local_path in
    let feed = F.parse system root (Some local_path) in

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
      Fake_system.assert_str_equal expected @@ Fake_system.expect @@ F.get_summary langs feed in

    test "Local feed (English GB)" ["en_GB.UTF-8"];
    test "Local feed (English)" ["en_US"];
    test "Local feed (Greek)" ["gr"];
    test "Fuente local" ["es_PT"];
    test "Local feed (English GB)" ["en_US"; "en_GB"; "es"];
    test "Local feed (English)" ["en_US"; "es"];
  );

  "feed-overrides">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let feed_url = Test_0install.feed_dir +/ "Hello.xml" in
    let digest = "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" in

    let overrides = F.load_feed_overrides config (`local_feed feed_url) in
    assert_equal None overrides.F.last_checked;
    assert_equal 0 (StringMap.cardinal overrides.F.user_stability);

    F.save_feed_overrides config (`local_feed feed_url) {
      F.user_stability = StringMap.add digest Developer overrides.F.user_stability;
      F.last_checked = Some 100.0;
    };

    (* Rating now visible *)
    let overrides = F.load_feed_overrides config (`local_feed feed_url) in
    assert_equal 1 (StringMap.cardinal overrides.F.user_stability);
    assert_equal Developer (StringMap.find digest overrides.F.user_stability);
    assert_equal (Some 100.0) overrides.F.last_checked;
  );
]
