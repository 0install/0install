(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open OUnit
open Support.Common
open Fake_system

open Support.Utils

class dummy_file_system =
  object
    inherit fake_system None

    method! readlink = function
      | "/link-to-etc" -> Some "/etc"
      | "/home/bob/to-fred" -> Some "../fred"
      | "/home/bob/loop1" -> Some "/home/bob/loop2"
      | "/home/bob/loop2" -> Some "/home/bob/loop1"
      | _ -> None

    method! getcwd () = "/home/bob"
  end

let suite = "utils">::: [
  "normpath">:: (fun () ->
    let check expected input =
      assert_str_equal expected @@ normpath input in

    if on_windows then (
      check "c:\\home\\bob" "c:\\home\\bob";
      check "c:\\home\\bob" "c:\\home\\bob\\";
      check "c:\\home\\bob" "c:\\\\home\\\\bob\\\\";
      check "c:\\home" "c:\\\\home\\\\bob\\\\..";
      check "c:\\home\\fred" "c:\\\\home\\\\bob\\.\\..\\.\\fred";
      check "..\\fred" "..\\\\fred";
      check ".." "..\\\\fred\\..";
    ) else (
      check "/home/bob" "/home/bob";
      check "/home/bob" "/home/bob/";
      check "/home/bob" "//home//bob//";
      check "/home" "//home//bob//..";
      check "/home/fred" "//home//bob/./.././fred";
      check "../fred" "..//fred";
      check ".." "..//fred/..";
    )
  );

  "realpath">:: (fun () ->
    skip_if (Sys.os_type = "Win32") "No symlinks on Windows";

    let system = new dummy_file_system in
    let check expected input =
      assert_str_equal expected @@ realpath (system :> system) input in

    check "/idontexist" "/idontexist";
    check "/" "/";
    check "/home/bob" "";
    check "/home/bob" ".";
    check "/foo" "/foo/bar/..";
    check "/home/fred/fred-data" "/home/bob/to-fred/fred-data";
    check "/home/fred/fred-data" "/home//bob//to-fred//fred-data//";
    check "/home/bob/loop1" "/home/bob/loop1";
    check "/home/bob/loop1/data" "/home/bob/loop1/data//";
    check "/home/bob/foo" "foo";
    check "/home/bob/foo" "./foo";
    check "/home/bob/in-bob" "/home/bob/missing/../in-bob";
    check "/home/in-fred" "/home/bob/to-fred/../in-fred";
    check "/home" "..";
  )
]
