(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interfacing with the old Python code *)

open General
open Support.Common
module Q = Support.Qdom

let slave_debug_level = ref None      (* Inherit our logging level *)
let default_interceptor ?xml:_ _request = None
let slave_interceptor = ref default_interceptor      (* Override for testing *)

let default_read_user_input prompt =
  (* Ask on stderr, because we may be writing XML to stdout *)
  prerr_string prompt; flush stdout;
  try input_line stdin
  with End_of_file -> raise_safe "Input aborted by user (end-of-file)"

let read_user_input = ref default_read_user_input

let get_command config args : string list =
  let result = ref [] in
  let try_with path =
    if config.system#file_exists path then (
      (* Note: on Windows, we need to specify "python" *)
      result := "python" :: path :: args;
      true
    ) else (
      false
    ) in
  let my_dir = Filename.dirname config.abspath_0install in
  let parent_dir = Filename.dirname my_dir in
  ignore (
    try_with (my_dir +/ "0install-python-fallback") ||                        (* When installed in /usr/bin XXX *)
    try_with (parent_dir +/ "0install-python-fallback") ||                    (* When running from ocaml directory *)
    try_with (Filename.dirname parent_dir +/ "0install-python-fallback") ||   (* When running from _build directory *)
    failwith "Can't find 0install-python-fallback command!"
  );
  assert (!result <> []);
  !result

let async fn =
  Lwt.ignore_result (
    try_lwt fn ()
    with ex -> log_warning ~ex "Unhandled error from Lwt thread"; Lwt.fail ex
  )

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

(* Read a line containing an integer.
   Returns [None] if the channel was closed.
   Reports an error if it didn't get an integer. *)
let read_int_opt chan : int option Lwt.t =
  try_lwt
    lwt line = Lwt_io.read_line chan in
    try Lwt.return @@ Some (int_of_string line)
    with Failure _ ->
      raise_safe "Invalid response from slave '%s' (expected integer). This is a bug." (String.escaped line)
  with Lwt_io.Channel_closed _ -> Lwt.return None

let do_input = function
  | [`String prompt] -> Lwt.return (`String (!read_user_input prompt))
  | _ -> raise_safe "Invalid request"

(** The Python can send requests to us. Other modules can register handlers for them here. *)
let handlers = ref (StringMap.singleton "input" do_input)

let register_handler op handler =
  handlers := StringMap.add op handler !handlers

(** Runs a Python slave process. Remembed to close the connection when done. *)
open Yojson.Basic
class slave config =
  (* let () = log_warning "CREATE SLAVE" in *)

  let system = config.system in

  let connection = ref None in
  
  let send_json c ?xml request : unit Lwt.t =
    log_info "Sending to Python: %s%s" (to_string request)
      (match xml with None -> "" | Some xml -> "\n" ^ (Q.to_utf8 xml));
    let data = to_string request in
    let buf = Buffer.create (String.length data + 16) in
    Buffer.add_string buf @@ Printf.sprintf "%8x" (String.length data);
    Buffer.add_string buf data;
    let () =
      match xml with
      | Some xml ->
          let xml_data = Q.to_utf8 xml in
          Buffer.add_string buf @@ Printf.sprintf "%8x" (String.length xml_data);
          Buffer.add_string buf xml_data
      | None -> () in

    let data = Buffer.contents buf in
    Lwt_io.write c#stdin data in

  let pending_replies = Hashtbl.create 10 in
  let take_ticket =
    let last_ticket = ref (Int64.zero) in
    fun () -> (last_ticket := Int64.add !last_ticket Int64.one; Int64.to_string !last_ticket) in

  let handle_invoke c ticket request () =
    lwt response =
      try
        lwt return_value =
          match request with
          | `List (`String op :: args) ->
              let cb =
                try StringMap.find op !handlers
                with Not_found -> raise_safe "No handler for JSON op '%s' (received from Python)" op in
              cb args
          | request -> raise_safe "Invalid request to OCaml: %s" (to_string request) in
        Lwt.return (`List [`String "ok"; return_value])
      with Safe_exception (msg, _) as ex ->
        log_warning ~ex "Returning error to Python";
        Lwt.return (`List [`String "error"; `String msg]) in
      send_json c @@ `List [`String "return"; `String ticket; response] in

  (* Read and process messages from stream until it is closed. *)
  let handle_messages c () =
    let rec loop () =
      match_lwt read_int_opt c#stdout with
      | None -> log_debug "handle_messages: channel closed, so stopping handler"; Lwt.return ()
      | Some l ->
          let buf = String.create l in
          lwt () = Lwt_io.read_into_exactly c#stdout buf 0 l in
          log_info "Message from Python: %s" buf;
          let response = from_string buf in
          match response with
          | `List [`String "invoke"; `String ticket; request] ->
            async @@ handle_invoke c ticket request;
            loop ()
          | `List [`String "return"; `String ticket; r] ->
              let resolver =
                try Hashtbl.find pending_replies ticket
                with Not_found -> raise_safe "Unknown ticket ID in JSON: %s" buf in
              Hashtbl.remove pending_replies ticket;
              Lwt.wakeup resolver r;
              loop ()
          | _ -> raise_safe "Invalid JSON from Python slave:%s" buf in
    loop () in

  let get_connection () =
    match !connection with
    | Some c -> c
    | None ->
        (* log_warning "START SLAVE"; *)
        let debug_args =
          let open Support.Logging in
          let t =
            match !slave_debug_level with
            | None -> !threshold
            | Some t -> t in
          match t with
          | Debug -> ["-v"]
          | Info -> []
          | Warning -> [] in

        let extra_args = List.concat [
          debug_args;
          bool_opt "--dry-run" config.dry_run;
          store_opts config.extra_stores;
          bool_opt "--offline" (config.network_use = Offline);
        ] in

        let argv = get_command config ("slave" :: extra_args) in
        let prog = Support.Utils.find_in_path_ex system (List.hd argv) in  (* "" requires Lwt 2.4 *)
        log_info "Starting Python slave: %s" (Support.Logging.format_argv_for_logging argv);
        let child = new Lwt_process.process (prog, Array.of_list argv) in
        
        connection := Some child;

        async (handle_messages child);

        child in

  object (self)
    method invoke : 'a. json -> ?xml:Q.element -> (json -> 'a) -> 'a = fun request ?xml parse_fn ->
      Lwt_main.run (self#invoke_async request ?xml parse_fn)

    (** Send a JSON message to the Python slave and return whatever data it sends back. *)
    method invoke_async : 'a. json -> ?xml:Q.element -> (json -> 'a) -> 'a Lwt.t = fun request ?xml parse_fn ->
      let response =
        match !slave_interceptor ?xml request with
        | Some reply -> reply
        | None ->
            let c = get_connection () in

            let (response, resolver) = Lwt.wait () in
            let ticket = take_ticket () in

            Hashtbl.add pending_replies ticket resolver;
            lwt () = send_json c ?xml (`List [`String "invoke"; `String ticket; request]) in
            response in

      match_lwt response with
        | `List [`String "error"; `String err] -> raise_safe "%s" err
        | `List [`String "ok"; r] -> (
            try Lwt.return (parse_fn r)
            with Safe_exception _ as ex ->
              reraise_with_context ex "... processing JSON response from Python slave:\n%s" (to_string r)
        )
        | response -> raise_safe "Invalid JSON response from Python slave:%s" (to_string response)

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
