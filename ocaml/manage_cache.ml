(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install store manage" command *)

open Options
open Support.Common

let handle options flags args =
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  if args <> [] then raise (Support.Argparse.Usage_error 1);
  let gui = options.slave#invoke_async (`List [`String "open-cache-explorer"]) (function
    | `Null -> ()
    | json -> raise_safe "Invalid response: %s" (Yojson.Basic.to_string json)
  ) in
  Lwt_main.run gui
