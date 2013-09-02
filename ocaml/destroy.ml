(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install destroy" command *)

open Options
open Support.Common

let handle options flags args =
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  match args with
  | [name] -> (
      match Zeroinstall.Apps.lookup_app options.config name with
      | None -> raise_safe "No such application '%s'" name
      | Some app -> Zeroinstall.Apps.destroy options.config app
  )
  | _ -> raise (Support.Argparse.Usage_error 1)
