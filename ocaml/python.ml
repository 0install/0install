(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interfacing with the old Python code *)

open Zeroinstall.General
open Support.Common

let get_command config args : string list =
  let result = ref [] in
  let try_with path =
    if config.system#file_exists path then (
      (* Note: on Windows, we need to specify "python" *)
      result := "python" :: path :: "--python-fallback" :: args;
      true
    ) else (
      false
    ) in
  let my_dir = Filename.dirname config.abspath_0install in
  let parent_dir = Filename.dirname my_dir in
  ignore (
    try_with (my_dir +/ "0launch") ||                        (* When installed in /usr/bin *)
    try_with (parent_dir +/ "0launch") ||                    (* When running from ocaml directory *)
    try_with (Filename.dirname parent_dir +/ "0launch") ||   (* When running from _build directory *)
    failwith "Can't find 0launch command!"
  );
  assert (!result <> []);
  !result

(** Run "python -m zeroinstall.cmd". If ../zeroinstall exists, put it in PYTHONPATH,
    otherwise use the system version of 0install. *)
let fallback_to_python config args =
  config.system#exec ~search_path:true (get_command config args)

let rec count_opt flag = function
  | 0 -> []
  | n -> flag :: count_opt flag (n - 1)

let bool_opt name = function
  | false -> []
  | true -> [name]

let rec store_opts = function
  | [] -> []
  | x::xs -> "--with-store" :: x :: store_opts xs

(** Invoke "0install [args]" and return the output. *)
let check_output_python options fn subcommand args =
  let open Options in
  let {config;gui;verbosity;extra_stores;extra_options=_;args=_;distro=_} = options in
  let extra_args = List.concat [
    bool_opt "--gui" (gui = Yes);
    bool_opt "--console" (gui = No);
    count_opt "-v" verbosity;
    bool_opt "--offline" (config.network_use = Offline);
    store_opts extra_stores;
  ] in
  Support.Utils.check_output config.system fn @@ get_command config @@ subcommand :: (extra_args @ args)
