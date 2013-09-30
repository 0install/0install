(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
module Stores = Zeroinstall.Stores
module Archive = Zeroinstall.Archive

let suite = "stores">::: [
  "alg-ranking">:: (fun () ->
    assert_equal ("sha256new", "678") @@ Stores.best_digest [
      ("sha1", "123");
      ("sha256new", "678");
      ("sha256", "345");
    ];

    Fake_system.assert_raises_safe "None of the candidate digest algorithms (odd) is supported" (lazy (
      Stores.best_digest [("odd", "123")] |> ignore
    ));
  );

  "get-type">:: (fun () ->
    Fake_system.assert_str_equal "application/x-bzip-compressed-tar" @@ Archive.type_from_url "http://example.com/archive.tar.bz2";
    Fake_system.assert_str_equal "application/zip" @@ Archive.type_from_url "http://example.com/archive.foo.zip";
    Fake_system.assert_raises_safe
      "No 'type' attribute on archive, and I can't guess from the name (http://example.com/archive.tar.bz2/readme)"
      (lazy (ignore @@ Archive.type_from_url "http://example.com/archive.tar.bz2/readme"));
  );

  "check-type">:: (fun () ->
    let system = (new Fake_system.fake_system None :> system) in
    Fake_system.assert_raises_safe
      "This package looks like a zip-compressed archive, but you don't have the \"unzip\" command I need to extract it. \
       Install the package containing it first." (lazy (Archive.check_type_ok system "application/zip"))
  );
]
