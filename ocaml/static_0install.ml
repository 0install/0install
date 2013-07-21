(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main executable for static (native or bytecode) builds.
    Portable bytecode uses 0install.ml instead. *)

(* Use the Unix module we're compiled with, rather than loading it dynamically. *)
module RealSystem = Support.System.RealSystem(Unix)

let () = Main.start new RealSystem.real_system
