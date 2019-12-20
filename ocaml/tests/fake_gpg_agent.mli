(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* A dummy gpg agent for unit-tests.
 * GnuPG >= 2.1 requires an agent, even though it doesn't need it for anything,
 * and there's no way to stop it trying to connect to it.
 * See: http://stackoverflow.com/questions/27459869/how-to-stop-gpg-2-1-spawning-many-agents-for-unit-testing *)

open Support.Common

(** [run dir] creates a socket in [dir] and accepts connections from gpg, returning
 * dummy responses to all commands. Cancel the thread when done. *)
val run : filepath -> unit Lwt.t

(** [with_gpg test] creates a temporary directory with a fake agent socket and runs [test tmpdir] inside it. *)
val with_gpg : (filepath -> unit) -> (unit -> unit)
