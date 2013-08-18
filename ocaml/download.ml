(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install download" command *)

open Support.Common
open Options

let handle options args =
  match args with
  | [arg] -> (
    ignore @@ Generic_select.handle options arg Zeroinstall.Helpers.Download_only;
    assert (options.extra_options = [])
  )
  | _ -> raise Support.Argparse.Usage_error
