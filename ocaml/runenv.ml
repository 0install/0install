(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* The stand-alone 0install-runenv.exe (only used on Windows) *)

module RealSystem = Support.System.RealSystem(Unix)

let () =
  let system = new RealSystem.real_system in
  Support.Utils.handle_exceptions (Runenv_shared.runenv system) (Array.to_list Sys.argv)
