(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* The main runenv code, used on all systems (POSIX and Windows) *)

open Support
open Support.Common

(** This is called in a new process by the launcher created by [Zeroinstall.Exec.ensure_runenv]. *)
let runenv (system:system) args =
  match args with
  | [] -> failwith "No args passed to runenv!"
  | arg0::args ->
    try
      let var = "zeroinstall_runenv_" ^ Filename.basename arg0 in
      let s = Support.Utils.getenv_ex system var in
      let open Yojson.Basic in
      let envargs = Util.convert_each Util.to_string (from_string s) in
      system#exec (envargs @ args)
    with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... launching %s" arg0
