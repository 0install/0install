(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
open Zeroinstall
open Zeroinstall.General

module U = Support.Utils
module G = Support.Gpg
module Basedir = Support.Basedir

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

  "check-signed">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let trust_db = new Zeroinstall.Trust.trust_db config in
    trust_db#trust_key "92429807C9853C0744A68B9AAE07828059A53CC1" ~domain:"foo";
    let slave = new Zeroinstall.Python.slave config in
    let downloader = new Zeroinstall.Downloader.downloader in
    let fetcher = new Zeroinstall.Fetch.fetcher config trust_db slave downloader in
    let foo_signed_xml = U.read_file config.system "foo.xml" in

    (* Unsigned *)
    Fake_system.assert_raises_safe
      "This is not a Zero Install feed! It should be an XML document, but it starts:\nhello"
      (lazy (G.verify config.system "hello" |> Lwt_main.run |> ignore));

    G.import_key config.system Test_gpg.thomas_key |> Lwt_main.run;

    (* Signed, wrong URL *)
    Fake_system.assert_raises_safe
      ("URL mismatch in feed:\n\
        http://foo/wrong expected\n\
        http://foo/ given in 'uri' attribute on <interface> at http://foo/wrong:3:97")
      (lazy (fetcher#import_feed (`remote_feed "http://foo/wrong") foo_signed_xml |> Lwt_main.run));

    (* Signed *)
    let feed_url = `remote_feed "http://foo/" in
    fetcher#import_feed feed_url foo_signed_xml |> Lwt_main.run;

    assert_equal ["http://foo/"] @@ StringSet.elements @@ Feed_cache.list_all_interfaces config;

    let new_xml = Feed_cache.get_cached_feed_path config feed_url |> Fake_system.expect |> U.read_file config.system in
    let (sigs, _) = G.verify config.system new_xml |> Lwt_main.run in
    let last_modified = trust_db#oldest_trusted_sig "foo" sigs in
    assert_equal (Some 1380109390.) last_modified;

    (* Updated *)
    let foo_signed_xml_new = U.read_file config.system "foo-new.xml" in

    let dryrun_fetcher = new Zeroinstall.Fetch.fetcher {config with dry_run = true} trust_db slave downloader in
    let out = Fake_system.capture_stdout (fun () ->
      dryrun_fetcher#import_feed feed_url foo_signed_xml_new |> Lwt_main.run;
    ) in
    assert (U.starts_with out "[dry-run] would cache feed http://foo/ as");

    fetcher#import_feed feed_url foo_signed_xml_new |> Lwt_main.run;

    (* Can't 'update' to an older copy *)
    Fake_system.assert_raises_safe
      ("New feed's modification time is before old version!\n\
        Interface: http://foo/\n\
        Old time: 2013-09-25T12:57:28Z\n\
        New time: 2013-09-25T12:43:10Z\n\
        Refusing update.")
      (lazy (fetcher#import_feed feed_url foo_signed_xml |> Lwt_main.run))
  );

  "test-list">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    assert (StringSet.is_empty @@ Feed_cache.list_all_interfaces config);
    let iface_dir = Basedir.save_path config.system (config_site +/ "interfaces") config.basedirs.Basedir.cache in
    U.touch config.system (iface_dir +/ "http%3a%2f%2ffoo");
    Fake_system.equal_str_lists ["http://foo"] @@ (StringSet.elements @@ Feed_cache.list_all_interfaces config)
  );
]
