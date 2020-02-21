(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0store-secure-add" command *)

open Zeroinstall.General
open Support

module Manifest = Zeroinstall.Manifest
module U = Support.Utils

let handle config args =
  (* Make all system files world-readable, even if the default system umask is more strict. *)
  ignore (Unix.umask 0o022);

  let system = config.system in

  if system#getenv "ENV_NOT_CLEARED" <> None then (
    Safe_exn.failf "Environment not cleared. Check your sudoers file."
  ) else if system#getenv "HOME" = Some "Unclean" then (
    Safe_exn.failf "$HOME not set. Check your sudoers file has 'always_set_home' turned on for zeroinst."
  ) else (
    match args with
    | [digest] ->
        let digest = Manifest.parse_digest digest in
        let manifest_data = U.read_file system ".manifest" in
        Manifest.copy_tree_with_verify system "." "/var/cache/0install.net/implementations" manifest_data digest
    | _ -> Safe_exn.failf "Usage: 0store-secure-add DIGEST"
  )
