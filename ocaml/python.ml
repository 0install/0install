(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interfacing with the old Python code *)

open Zeroinstall.General
open Support.Common
open Options

let finally = Support.Utils.finally

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

(** Runs a Python slave process. Remembed to close the connection when done. *)
open Yojson.Basic
class slave options =
  let system = options.config.system in
  let (child_stdin_r, child_stdin_w) = Unix.pipe () in
  let (child_stdout_r, child_stdout_w) = Unix.pipe () in

  let extra_args =
    let open Options in
    let {config;gui;verbosity;extra_stores;extra_options=_;args=_;distro=_} = options in
    List.concat [
      bool_opt "--gui" (gui = Yes);
      bool_opt "--console" (gui = No);
      count_opt "-v" verbosity;
      bool_opt "--offline" (config.network_use = Offline);
      store_opts extra_stores;
    ] in

  let argv = get_command options.config ("slave" :: extra_args) in
  let child_pid =
    try
      Unix.set_close_on_exec child_stdin_w;
      Unix.set_close_on_exec child_stdout_r;
      finally (fun () -> Unix.close child_stdin_r; Unix.close child_stdout_w) ()
              (fun () -> Some (system#create_process argv child_stdin_r child_stdout_w Unix.stderr))
    with ex ->
      Unix.close child_stdin_w;
      Unix.close child_stdout_r;
      raise ex in
  
  let to_child = Unix.out_channel_of_descr child_stdin_w in
  let from_child = Unix.in_channel_of_descr child_stdout_r in

  object
    (** Send a JSON message to the Python slave and return whatever data it sends back. *)
    method invoke : 'a. json -> (json -> 'a) -> 'a = fun request parse_fn ->
      let data = to_string request in
      log_info "Sending to Python: %s" data;
      Printf.fprintf to_child "%d\n" (String.length data);
      output_string to_child data;
      flush to_child;

      let l = int_of_string @@ input_line from_child in
      let buf = String.create l in
      really_input from_child buf 0 l;
      log_info "Response from Python: %s" buf;
      let response = from_string buf in
      match response with
      | `List [`String "error"; `String err] -> raise_safe "%s" err
      | `List [`String "ok"; r] -> (
          try parse_fn r
          with Safe_exception _ as ex -> reraise_with_context ex "... processing JSON response from Python slave:\n%s" buf
      )
      | _ -> raise_safe "Invalid JSON response from Python slave:%s" buf

    method close =
      match child_pid with
      | None -> log_warning "Already closed Python slave!"
      | Some pid ->
          log_info "Closing connection to slave";
          close_out to_child;
          close_in from_child;
          system#reap_child pid;
          log_info "Slave terminated"
  end
