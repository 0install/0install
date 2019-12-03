(* Copyright (C) 2019, Thomas Leonard
   See the README file for details, or visit http://0install.net. *)

open OUnit
open Lwt.Infix

let suite = "bug-reporter">::: [
  "submit">:: Server.with_server (fun (_config, _fake_system) server ->
    server#expect [
      [("/api/report-bug/", `ServeFile "bug-reply")];
    ];
    Lwt_main.run begin
      Zeroinstall.Gui.send_bug_report "http://example.com/foo.xml" "Broken" >>= fun reply ->
      assert_equal ~printer:(fun x -> x) "Thanks\n" reply;
      Lwt.return_unit
    end
  );
]
