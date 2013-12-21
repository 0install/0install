(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Options

let handle options flags args =
  let tools = options.tools in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  let gui = tools#ui in
  let config = options.config in

  let finished =
    match args with
    | [] ->
        gui#open_app_list_box;
    | [arg] ->
        let url = Generic_select.canonical_iface_uri config.system arg in
        gui#open_add_box url
    | _ -> raise (Support.Argparse.Usage_error 1) in

  Lwt_main.run finished
