(* Copyright (C) 2016, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A dialog box for confirming whether to trust a feed's GPG key(s). *)

open Support
open Zeroinstall

val confirm_keys :
  Gpg.t ->
  Trust.trust_db ->
  ?parent:#GWindow.window_skel ->
  Feed_url.remote_feed ->
  (Gpg.fingerprint * (Progress.key_vote_type * string) list Lwt.t) list ->
  Gpg.fingerprint list Lwt.t
(** [confirm_keys gpg trust_db feed hints] asks the user to confirm which keys they trust to sign [feed].
    [hints] is displayed to the user to help them decide.
    The result is a list of fingerprints which should now be trusted. *)
