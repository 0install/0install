(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
open Zeroinstall.General
module G = Support.Gpg

let err_sig = "<?xml version=\"1.0\" ?>\n\
<?xml-stylesheet type='text/xsl' href='interface.xsl'?>\n\
<interface xmlns=\"http://zero-install.sourceforge.net/2004/injector/interface\">\n\
  <name>test</name>\n\
  <summary>test</summary>\n\
</interface>\n\
<!-- Base64 Signature\n\
iJwEAAECAAYFAk1NVyAACgkQerial32qo5eVCgP/RYEzT43M2Dj3winnkX2HQDO2Fx5dq83pmidd\n\
LDEID3FxbuIpMUP/2rvPmNM3itRo/J4R2xkM65TEol/55uxDC1bbuarKf3wbgwEF60srFEDeeiYM\n\
FmTQtWYPtrzAGtNRTgKfD75xk9lcM2GHmKNlgSQ7G8ZsfL6KaraF4Wa6nqU=\n\
\n\
-->\n\
"

let bad_sig = "<?xml version='1.0'?>\n\
<ro0t/>\n\
<!-- Base64 Signature\n\
iD8DBQBDuChIrgeCgFmlPMERAnGEAJ0ZS1PeyWonx6xS/mgpYTKNgSXa5QCeMSYPHhNcvxu3f84y\n\
Uk7hxHFeQPo=\n\
-->\n\
"

let invalid_xmls_sigs = [
("Bad signature block: last line is not end-of-comment",
"<!-- Base64 Signature\n\
");
("No signature block in XML. Maybe this file isn't signed?",
"<!-- Base64 Sig\n\
iD8DBQBDtpK9rgeCgFmlPMERAg0gAKCaJhXFnk\n\
-->\n\
");
("No signature block in XML. Maybe this file isn't signed?",
"<!-- Base64 Signature data\n\
iD8DBQBDtpK9rgeCgFmlPMERAg0gAKCaJhXFnk\n\
-->\n\
");
("Bad signature block: last line is not end-of-comment",
"<!-- Base64 Signature\n\
iD8DBQBDtpK9rgeCgFmlPMERAg0gAKCaJhXFnk\n\
WZRBLT0an56WYaBODukSsf4=\n\
--> More\n\
");
("Invalid characters found in base 64 encoded signature",
"<!-- Base64 Signature\n\
iD8DBQBDtpK9rgeCgFmlPMERAg0gAKCaJhXFnk\n\
WZRBLT0an56WYaBODukSsf4=\n\
=zMc+\n\
-->\n\
");
("Invalid characters found in base 64 encoded signature",
"<!-- Base64 Signature\n\
iD8DBQBDtpK9rge<CgFmlPMERAg0gAKCaJhXFnk\n\
WZRBLT0an56WYaBODukSsf4=\n\
-->\n\
")
]

let good_sig = "<?xml version='1.0'?>\n\
<root/>\n\
<!-- Base64 Signature\n\
iD8DBQBDuChIrgeCgFmlPMERAnGEAJ0ZS1PeyWonx6xS/mgpYTKNgSXa5QCeMSYPHhNcvxu3f84y\n\
Uk7hxHFeQPo=\n\
-->\n\
"

let thomas_fingerprint = "92429807C9853C0744A68B9AAE07828059A53CC1"

let thomas_key =
"-----BEGIN PGP PUBLIC KEY BLOCK-----\n\
Version: GnuPG v1.0.7 (GNU/Linux)\n\
\n\
mQGiBD1JRcERBADIOjwNaBjmv44a3DPJeVwqrdVO6nuYF16UwKXTAh3ZZNAYecD8\n\
a7opNf4yt3TofSKfT2bEiv/hIdAy3LGjKQg54Dou1EqhB8o90RNl5NeWmHIb82Jp\n\
bCSbAXfaEaz6MEIg0MTHBcvtAOHZbKoBuBO5b6nbokmvcyWZXJHQ9zs9dwCg4FSX\n\
cdVBExg+2iBzEzpGyK4EFrsEAKTxf2YoLGihB1HDknvlAWIfa5dBZI9c7pdbpmkW\n\
6nZZ+SEHC9j1VSWFbB1fpA217BPaF6bmKmLoZEdmYLItriy2GEeEnbAcqd9QvQTr\n\
RnXzBlOanC4OHqT0dvBLMH60TsWN2ZQQ3hPInI+CAdgquDzqoZY699moo+NXZZky\n\
bB12A/9aI83jzl8gX7j61hkdk97rL/tcrdp8nGe2mS7y6tLodh89kp0IAD3Cn9pu\n\
bQpEVMSIAO6ocMIMa6IhiSW+axKcW44JaOXtxFhLi9RDnGhds9LKPSB+Qoyfpxkk\n\
zcAjNFcR2tDMOaDD5+/cZHSfKhT6TuWiiAzhhZEw3ikBnhCQYLQtVGhvbWFzIExl\n\
b25hcmQgPHRhbDE5N0B1c2Vycy5zb3VyY2Vmb3JnZS5uZXQ+iFkEExECABkFAj1J\n\
RcEECwcDAgMVAgMDFgIBAh4BAheAAAoJEK4HgoBZpTzBvdUAoMYjTfjeiOLyBF+V\n\
6tm/8Da/VIS2AKDXlYeko8yY/DMZDy9uLrmlrOLYmrkBDQQ9SUXGEAQA40HXju3P\n\
alvuv73gX0PcNC1lVTE3X15DTdvQLCCCt0H62A73i22c80CfGj3LaVybOHPjuM2/\n\
phu69zf5S3wHFJXYzezkVO7Yf/0MRyQslviy/+pWdbBJnVaE+qF3wggvcHIddatd\n\
roJ7q1haFl+cmIf43+EqoDZWVtKejSyeuGsAAwUEAOIrD9sPoing4huSDDgNJ9bo\n\
DbG3YkT9GROZ2FMdz12pwjUvSSxa8Yh4zJQ1EkKprSCD7QZMu9FMudzuwHZweJN1\n\
OhG+amFSsHmYl4Cbql9401lZvpvWoBhi54eKGMaxDNIGyojWJD8FTiC2eUrMwu3G\n\
rXu8m0nbaNiXL88Kv6EHiEYEGBECAAYFAj1JRcYACgkQrgeCgFmlPMHF8ACfehcT\n\
YkxNRG4ozQP5gwBO8CDdGVAAn0P7xyghEym4gcy7/rvwkY7JIar5\n\
=wks3\n\
-----END PGP PUBLIC KEY BLOCK-----\n\
"

let with_tal_key test =
  Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    Lwt_main.run @@ G.import_key config.system thomas_key;
    test config.system
  )

let suite = "gpg">::: [
  "import-bad">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    try Lwt_main.run @@ G.import_key config.system "Bad key"; assert false
    with Safe_exception _ -> ()
  );

  "error-sig">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let sigs, warnings = Lwt_main.run @@ G.verify config.system err_sig in
    assert (warnings <> "");
    match sigs with
    | [ G.ErrSig (G.UnknownKey "7AB89A977DAAA397") ] -> ()
    | _ -> assert_failure "Expected ErrSig"
  );

  "bad-sig">:: with_tal_key (fun system ->
    let sigs, warnings = Lwt_main.run @@ G.verify system bad_sig in
    assert (warnings <> "");
    match sigs with
    | [ G.BadSig "AE07828059A53CC1" ] -> ()
    | _ -> assert_failure "Expected BadSig"
  );

  "invalid-sigs">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in

    invalid_xmls_sigs |> List.iter (fun (expected, xml) ->
      let xml = "<?xml version='1.0'?>\n<root/>\n" ^ xml in
      try ignore @@ Lwt_main.run @@ G.verify config.system xml; assert_failure expected
      with Safe_exception (msg, _) ->
        Fake_system.assert_str_equal expected msg
    )
  );

  "good-sig">:: with_tal_key (fun system ->
    let (sigs, _stderr) = Lwt_main.run @@ G.verify system good_sig in
    match sigs with
    | [ G.ValidSig details ] -> 
        Fake_system.assert_str_equal "92429807C9853C0744A68B9AAE07828059A53CC1" details.G.fingerprint;
        let name = Fake_system.expect @@ Lwt_main.run @@ G.get_key_name system details.G.fingerprint in
        Fake_system.assert_str_equal "Thomas Leonard <tal197@users.sourceforge.net>" name
    | _ -> assert_failure "Expected ValidSig"
  );

  "not-xml">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in

    Fake_system.assert_raises_safe "This is not a Zero Install feed! It should be an XML document, but it starts:\nHello"
      (lazy (ignore @@ Lwt_main.run @@ G.verify config.system "Hello"));
  );

  "no-sigs">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let empty_sig = "<?xml version='1.0'?><root/>\n<!-- Base64 Signature\n-->" in
    let (sigs, _stderr) = Lwt_main.run @@ G.verify config.system empty_sig in
    assert_equal [] sigs;
  );

  "load-keys">:: with_tal_key (fun system ->
    assert_equal StringMap.empty @@ Lwt_main.run @@ G.load_keys system [];
    let keys = Lwt_main.run @@ G.load_keys system [thomas_fingerprint] in
    let info = StringMap.find thomas_fingerprint keys in
    Fake_system.assert_str_equal "Thomas Leonard <tal197@users.sourceforge.net>" (Fake_system.expect info.G.name)
  );
]
