(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
open OUnit
module T = Zeroinstall.Trust

let with_trust_db (fn:_ -> unit) =
  Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let trust_db = new T.trust_db config in
    fn trust_db
  )

let thomas_fingerprint = "92429807C9853C0744A68B9AAE07828059A53CC1"

let suite = "trust">::: [
  "init">:: with_trust_db (fun db ->
    assert_equal false @@ db#is_trusted thomas_fingerprint ~domain:"gimp.org";
    assert_equal false @@ db#is_trusted "1234" ~domain:"gimp.org";
  );

  "add-invalid">:: with_trust_db (fun db ->
    assert_equal `Caught @@
      try db#trust_key "hello" ~domain:"gimp.org"; `Fail
      with Assert_failure _ -> `Caught
  );

  "add">:: with_trust_db (fun db ->
    let domain = "example.com" in
    assert_equal false @@ db#is_trusted "1234" ~domain;
    db#trust_key "1234" ~domain:"*";
    assert_equal true @@ db#is_trusted "1234" ~domain;
    assert_equal false @@ db#is_trusted "1236" ~domain;

    db#untrust_key "1234" ~domain:"*";
    assert_equal false @@ db#is_trusted "1234" ~domain;
  );

  "add-domain">:: with_trust_db (fun db ->
    assert_equal false @@ db#is_trusted "1234" ~domain:"0install.net";
    db#trust_key "1234" ~domain:"*";
    assert_equal ["*"]    @@ XString.Set.elements @@ db#get_trust_domains "1234";
    assert_equal ["1234"] @@ XString.Set.elements @@ db#get_keys_for_domain "*";
    assert_equal []       @@ XString.Set.elements @@ db#get_trust_domains "bob";

    assert_equal true @@ db#is_trusted "1234" ~domain:"0install.net";
    assert_equal true @@ db#is_trusted "1234" ~domain:"rox.sourceforge.net";
    assert_equal false @@ db#is_trusted "1236" ~domain:"0install.net";

    db#untrust_key "1234" ~domain:"*";
    assert_equal false @@ db#is_trusted "1234" ~domain:"rox.sourceforge.net";

    db#trust_key "1234" ~domain:"0install.net";
    db#trust_key "1234" ~domain:"gimp.org";
    db#trust_key "1236" ~domain:"gimp.org";
    assert_equal true @@ db#is_trusted "1234" ~domain:"0install.net";
    assert_equal true @@ db#is_trusted "1234" ~domain:"gimp.org";
    assert_equal false @@ db#is_trusted "1234" ~domain:"rox.sourceforge.net";

    assert_equal ["1234"; "1236"] @@ XString.Set.elements @@ db#get_keys_for_domain "gimp.org";

    assert_equal [] @@ XString.Set.elements @@ db#get_trust_domains "99877";
    assert_equal ["0install.net"; "gimp.org"] @@ XString.Set.elements @@ db#get_trust_domains "1234";
  );

  "parallel">:: Fake_system.with_tmpdir (fun tmpdir ->
    let domain = "example.com" in
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let a = new T.trust_db config in
    let b = new T.trust_db config in
    a#trust_key "1" ~domain;
    assert_equal true @@ b#is_trusted "1" ~domain;
    b#trust_key "2" ~domain;
    a#untrust_key "1" ~domain;
    assert_equal false @@ a#is_trusted "1" ~domain;
    assert_equal true @@ a#is_trusted "2" ~domain;
  );

  "domain">:: (fun () ->
    assert_equal "example.com:8080" @@ T.domain_from_url (`Remote_feed "http://fred:bob@example.com:8080/foo");
    let check_fails url =
      let escape url = Str.global_replace (Str.regexp_string "*") "\\*" url in
      Fake_system.assert_raises_safe ("Failed to parse HTTP URL '" ^ (escape url) ^ "'") (lazy (ignore @@ T.domain_from_url (`Remote_feed url))) in
    check_fails "/tmp/feed.xml";
    check_fails "http:///foo";
    check_fails "http://*/foo";
    check_fails "";
  );
]
