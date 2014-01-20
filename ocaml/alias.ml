(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open Zeroinstall.General
open Options

let handle options flags args =
  match args with
  | [name] -> raise_safe "ERROR: '0alias' has been removed; use '0install update' instead:\n0install update alias:%s" name
  | [name; iface] ->
      options.config.system#print_string "(\"0alias\" is deprecated; using \"0install add\" instead)\n";
      Add.handle options flags [name; iface]
  | _ -> raise_safe "ERROR: '0alias' has been removed; use '0install add' instead"
