(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
open Options

let handle options flags args =
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );

  match args with
  | [name] -> raise_safe "ERROR: '0alias' has been removed; use '0install update' instead:\n0install update alias:%s" name
  | [name; iface] -> raise_safe "ERROR: '0alias' has been removed; use '0install add' instead:\n0install add %s %s" name iface
  | _ -> raise_safe "ERROR: '0alias' has been removed; use '0install add' instead"
