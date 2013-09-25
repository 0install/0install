(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
open Zeroinstall
open Zeroinstall.General

module U = Support.Utils

let cache_path_for config url = Feed_cache.get_save_cache_path config (`remote_feed url)

let suite = "feed-cache">::: [
  "is-stale">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in

    let url = "http://localhost:8000/Hello" in

    fake_system#add_file (cache_path_for config url) (Test_0install.feed_dir +/ "Hello");

    let one_second = {config with freshness = Some Int64.one} in
    let long = {config with freshness = Some (fake_system#time +. 10.0 |> Int64.of_float)} in
    let never = {config with freshness = None} in

    assert (Feed_cache.is_stale never url);         (* Stale because no last checked time *)
    fake_system#set_time 100.0;
    Feed.update_last_checked_time config url;
    fake_system#set_time 200.0;

    assert (Feed_cache.is_stale one_second url);
    assert (not (Feed_cache.is_stale long url));
    assert (not (Feed_cache.is_stale never url));
    Feed_cache.mark_as_checking config (`remote_feed url);
    assert (not (Feed_cache.is_stale one_second url))
  );

  "check-attempt">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    assert_equal None @@ Feed_cache.get_last_check_attempt config "http://foo/bar.xml";

    fake_system#set_time 100.0;
    Feed_cache.mark_as_checking config (`remote_feed "http://foo/bar.xml");
    let () =
      match Feed_cache.get_last_check_attempt config "http://foo/bar.xml" with
      | Some 100.0 -> ()
      | _ -> assert false in

    assert_equal None @@ Feed_cache.get_last_check_attempt config "http://foo/bar2.xml"
  );
]
