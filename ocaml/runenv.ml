(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)


module RealSystem = Support.System.RealSystem(Unix)

let () =
  let system = new RealSystem.real_system in
  Support.Utils.handle_exceptions (Zeroinstall.Exec.runenv system) (Array.to_list Sys.argv)
