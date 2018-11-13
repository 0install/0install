(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install download" command *)

open Options

let handle options flags args =
  let select_opts = ref [] in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
    | #binary_select_option | `ShowHuman | `ShowXML | `Refresh as o -> select_opts := o :: !select_opts
  );
  match args with
  | [arg] -> ignore (Generic_select.handle options !select_opts arg `Download_only)
  | _ -> raise (Support.Argparse.Usage_error 1)
