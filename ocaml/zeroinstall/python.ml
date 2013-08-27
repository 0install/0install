(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interfacing with the old Python code *)

open General
open Support.Common
module Q = Support.Qdom

let slave_debug_level = ref None      (* Inherit our logging level *)

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

let bool_opt name = function
  | false -> []
  | true -> [name]

let rec store_opts = function
  | [] -> []
  | x::xs -> "--with-store" :: x :: store_opts xs

type child_connection = {
  child_pid : int;
  to_child : out_channel;
  from_child : in_channel;
}

(** Runs a Python slave process. Remembed to close the connection when done. *)
open Yojson.Basic
class slave config =
  (* let () = log_warning "CREATE SLAVE" in *)

  let system = config.system in

  let connection = ref None in
  
  let get_connection () =
    (* log_warning "START SLAVE"; *)
    match !connection with
    | Some c -> c
    | None ->
        let debug_args =
          let open Support.Logging in
          let t =
            match !slave_debug_level with
            | None -> !threshold
            | Some t -> t in
          match t with
          | Debug -> ["-vv"]
          | Info -> ["-v"]
          | Warning -> [] in

        let extra_args = List.concat [
          debug_args;
          bool_opt "--dry-run" config.dry_run;
          store_opts config.extra_stores;
          bool_opt "--offline" (config.network_use = Offline);
        ] in

        let argv = get_command config ("slave" :: extra_args) in
        let child = new Lwt_process.process ("", Array.of_list argv) in
        
        connection := Some child;
        child in

  let send_json c ?xml request : unit Lwt.t =
      let data = to_string request in
      log_info "Sending to Python: %s" data;
      lwt () = Lwt_io.fprintf c#stdin "%d\n%s" (String.length data) data in
      match xml with
      | Some xml ->
          let data = Q.to_utf8 xml in
          log_info "... with XML: %s" data;
          Lwt_io.fprintf c#stdin "%d\n%s" (String.length data) data
      | None -> Lwt.return () in

  object (self)
    method invoke : 'a. json -> ?xml:Q.element -> (json -> 'a) -> 'a = fun request ?xml parse_fn ->
      Lwt_main.run (self#invoke_async request ?xml parse_fn)

    (** Send a JSON message to the Python slave and return whatever data it sends back. *)
    method invoke_async : 'a. json -> ?xml:Q.element -> (json -> 'a) -> 'a Lwt.t = fun request ?xml parse_fn ->
      let c = get_connection () in

      lwt () = send_json c ?xml request in

      (* Normally we just get a single reply, but we might have to handle some input requests first. *)
      let rec loop () =
        lwt l =
          lwt line = Lwt_io.read_line c#stdout in
          try Lwt.return @@ int_of_string line
          with Failure _ -> raise_safe "Invalid response from slave '%s' (expected integer). This is a bug." (String.escaped line) in
        let buf = String.create l in
        lwt () = Lwt_io.read_into_exactly c#stdout buf 0 l in
        log_info "Response from Python: %s" buf;
        let response = from_string buf in
        match response with
        | `List [`String "input"; `String prompt] ->
            (* Ask on stderr, because we may be writing XML to stdout *)
            prerr_string prompt; flush stdout;
            let user_input = input_line stdin in
            lwt () = send_json c (`String user_input) in
            loop ()
        | `List [`String "error"; `String err] -> raise_safe "%s" err
        | `List [`String "ok"; r] -> (
            try Lwt.return (parse_fn r)
            with Safe_exception _ as ex -> reraise_with_context ex "... processing JSON response from Python slave:\n%s" buf
        )
        | _ -> raise_safe "Invalid JSON response from Python slave:%s" buf
      in loop ()

    method close =
      Lwt_main.run (self#close_async)

    method close_async =
      (* log_warning "CLOSE SLAVE"; *)
      match !connection with
      | None -> Lwt.return ()
      | Some c ->
          log_info "Closing connection to slave";
          lwt status = c#close in
          Support.System.check_exit_status status;
          connection := None;
          log_info "Slave terminated";
          Lwt.return ()

    method system = system
  end
