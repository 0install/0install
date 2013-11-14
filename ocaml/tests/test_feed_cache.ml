(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
open Zeroinstall
open Zeroinstall.General

module F = Zeroinstall.Feed
module U = Support.Utils
module G = Support.Gpg
module Q = Support.Qdom
module Basedir = Support.Basedir

let cache_path_for config url = Feed_cache.get_save_cache_path config url

let suite = "feed-cache">::: [
  "is-stale">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, fake_system) = Fake_system.get_fake_config (Some tmpdir) in

    let url = `remote_feed "http://localhost:8000/Hello" in

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
    Feed_cache.mark_as_checking config url;
    assert (not (Feed_cache.is_stale one_second url))
  );

  "check-attempt">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let bar = `remote_feed "http://foo/bar.xml" in
    assert_equal None @@ Feed_cache.get_last_check_attempt config bar;

    fake_system#set_time 100.0;
    Feed_cache.mark_as_checking config bar;
    let () =
      match Feed_cache.get_last_check_attempt config bar with
      | Some 100.0 -> ()
      | _ -> assert false in

    assert_equal None @@ Feed_cache.get_last_check_attempt config (`remote_feed "http://foo/bar2.xml")
  );

  "check-signed">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let trust_db = new Zeroinstall.Trust.trust_db config in
    trust_db#trust_key "92429807C9853C0744A68B9AAE07828059A53CC1" ~domain:"foo";
    let downloader = new Zeroinstall.Downloader.downloader Fake_system.null_ui ~max_downloads_per_site:2 in
    let slave = new Zeroinstall.Python.slave config in
    let distro = new Zeroinstall.Distro.generic_distribution slave in
    let fetcher = new Zeroinstall.Fetch.fetcher config trust_db downloader distro Fake_system.null_ui in
    let foo_signed_xml = U.read_file config.system (Fake_system.tests_dir +/ "foo.xml") in

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
    let foo_signed_xml_new = U.read_file config.system (Fake_system.tests_dir +/ "foo-new.xml") in

    let dryrun_fetcher = new Zeroinstall.Fetch.fetcher {config with dry_run = true} trust_db downloader distro Fake_system.null_ui in
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

  "extra-feeds">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    let iface = "http://test/test" in

    let iface_config = Feed_cache.load_iface_config config iface in
    assert_equal None iface_config.Feed_cache.stability_policy;
    Feed_cache.save_iface_config config iface iface_config;
    let iface_config = Feed_cache.load_iface_config config iface in
    assert_equal None iface_config.Feed_cache.stability_policy;

    Feed_cache.save_iface_config config iface {
      Feed_cache.stability_policy = Some Developer;
      Feed_cache.extra_feeds = [
        { F.feed_src = `remote_feed "http://sys-feed"; F.feed_os = None; F.feed_machine = None; F.feed_langs = None; F.feed_type = F.Distro_packages };
        { F.feed_src = `remote_feed "http://user-feed"; F.feed_os = Some "Linux"; F.feed_machine = None; F.feed_langs = None; F.feed_type = F.User_registered };
      ];
    };

    (* (Distro_packages feed is not saved) *)
    let iface_config = Feed_cache.load_iface_config config iface in
    assert_equal (Some Developer) iface_config.Feed_cache.stability_policy;
    begin match iface_config.Feed_cache.extra_feeds with
    | [ {F.feed_src = `remote_feed "http://user-feed"; F.feed_os = Some "Linux"; F.feed_machine = None; _ } ] -> ()
    | _ -> assert false end;
  );

  "site-packages">:: Fake_system.with_fake_config (fun (config, _fake_system) ->
    (* The old system (0install < 1.9):
     * - 0compile stores implementations to ~/.cache, and
     * - adds to extra_feeds
     *
     * The middle system (0install 1.9..1.12)
     * - 0compile stores implementations to ~/.local/0install.net/site-packages
     *   but using an obsolete escaping scheme, and
     * - modern 0install finds them via extra_feeds
     *
     * The new system (0install >= 1.13):
     * - 0compile stores implementations to ~/.local/0install.net/site-packages, and
     * - 0install finds them automatically

     * For backwards compatibility, 0install >= 1.9:
     * - writes discovered feeds to extra_feeds
     * - skips such entries in extra_feeds when loading
     *)

    let expected_escape = "section__prog_5f_1.xml" in

    let meta_dir = Basedir.save_path config.system
      ("0install.net" +/ "site-packages" +/ "http" +/ "example.com" +/ expected_escape +/ "1.0" +/ "0install")
      config.basedirs.Basedir.data in
    let feed = meta_dir +/ "feed.xml" in
    U.copy_file config.system (Test_0install.feed_dir +/ "Local.xml") feed 0o644;

    (* Check that we find the feed without us having to register it *)
    let iface = "http://example.com/section/prog_1.xml" in
    let iface_config = Feed_cache.load_iface_config config iface in
    begin match iface_config.Feed_cache.extra_feeds with
    | [ {F.feed_type = F.Site_packages; _} ] -> ()
    | _ -> assert false end;

    (* Check that we write it out, so that older 0installs can find it *)
    Feed_cache.save_iface_config config iface iface_config;

    let config_file = Fake_system.expect @@ Config.load_first_config ("0install.net" +/ "injector" +/
                                            "interfaces" +/ "http:##example.com#section#prog_1.xml") config in
    let doc = Q.parse_file config.system config_file in

    let is_feed elem = (ZI.tag elem = Some "feed") in
    let feed_node = Fake_system.expect @@ Q.find is_feed doc in
    assert_equal "True" @@ ZI.get_attribute "is-site-package" feed_node;

    (* Check we ignore this element *)
    let iface_config = Feed_cache.load_iface_config config iface in
    assert_equal 1 @@ List.length iface_config.Feed_cache.extra_feeds;

    (* Check feeds are automatically removed again *)
    let site_dir = Fake_system.expect @@ Basedir.load_first config.system
      ("0install.net" +/ "site-packages" +/ "http" +/ "example.com" +/ expected_escape)
      config.basedirs.Basedir.data in
    U.rmtree config.system ~even_if_locked:false site_dir;

    let iface_config = Feed_cache.load_iface_config config iface in
    assert_equal 0 @@ List.length iface_config.Feed_cache.extra_feeds;
  );
]
