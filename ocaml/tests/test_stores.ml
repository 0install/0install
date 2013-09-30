(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open OUnit
open Zeroinstall.General
module Stores = Zeroinstall.Stores

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
]
