(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Configuration settings *)

open General
open Support.Common

let parse_network_use = function
  | "full" -> Full_network
  | "minimal" -> Minimal_network
  | "off-line" -> Offline
  | other ->
      Support.Logging.log_warning "Unknown network use '%s'" other;
      Full_network

let format_network_use = function
  | Full_network -> "full"
  | Minimal_network -> "minimal"
  | Offline -> "off-line"

let parse_bool s =
  match String.lowercase_ascii s with
  | "true" -> true
  | "false" -> false
  | x -> log_warning "Not a boolean '%s'" x; false

let format_bool = function
  | false -> "False"
  | true -> "True"

let parse_optional_string = function
  | "" -> None
  | x -> Some x

let format_freshness = function
  | None -> "0"
  | Some s -> Int64.to_string (Int64.of_float s)

let load_config config =
  let handle_ini_mapping = function
    | "global" -> (function
      | ("freshness", freshness) ->
          let value = float_of_string freshness in
          if value > 0.0 then
            config.freshness <- Some value
          else
            config.freshness <- None
      | ("network_use", use) -> config.network_use <- parse_network_use use
      | ("help_with_testing", help) -> config.help_with_testing <- parse_bool help
      | ("auto_approve_keys", value) -> config.auto_approve_keys <- parse_bool value
      | ("key_info_server", value) -> config.key_info_server <- parse_optional_string value
      | _ -> ()
    )
    | _ -> ignore in    (* other [sections] *)

  match Paths.Config.(first global) config.paths with
  | None -> ()
  | Some path -> Support.Utils.parse_ini config.system handle_ini_mapping path

let default_key_info_server = Some "https://keylookup.0install.net"

(** [get_default_config path_to_0install] creates a configuration from the current environment.
    [path_to_0install] is used when creating launcher scripts. If it contains no slashes, then
    we search for it in $PATH.
  *)
let get_default_config system path_to_prog =
  let abspath_prog = if String.contains path_to_prog Filename.dir_sep.[0] then
    Support.Utils.abspath system path_to_prog
  else
    Support.Utils.find_in_path_ex system path_to_prog
  in

  let abspath_0install =
    let name = Filename.basename abspath_prog in
    if Support.XString.starts_with name "0install" then abspath_prog
    else (
      (Filename.dirname abspath_prog +/ "0install") ^
        if Filename.check_suffix name ".exe" then ".exe" else ""
    ) in

  let paths = Paths.get_default system in

  let config = {
    paths;
    stores = Stores.get_default_stores system paths;
    extra_stores = [];
    abspath_0install;
    freshness = Some (30. *. days);
    network_use = Full_network;
    mirror = Some "http://roscidus.com/0mirror";
    key_info_server = default_key_info_server;
    dry_run = false;
    help_with_testing = false;
    auto_approve_keys = true;
    system;
    langs = Support.Locale.score_langs (Support.Locale.get_langs system);
  } in

  load_config config;

  config

(** Write global settings. *)
let save_config config =
  let path = Paths.Config.(save_path global) config.paths in
  if config.dry_run then
    Dry_run.log "Would write config to %S" path
  else (
    path |> config.system#atomic_write [Open_wronly] ~mode:0o644 (fun ch ->
      output_string ch "[global]\n";

      Printf.fprintf ch "help_with_testing = %s\n" (format_bool config.help_with_testing);
      Printf.fprintf ch "network_use = %s\n" (format_network_use config.network_use);
      Printf.fprintf ch "freshness = %s\n" (format_freshness config.freshness);
      Printf.fprintf ch "auto_approve_keys = %s\n" (format_bool config.auto_approve_keys);
      let key_info_server_str =
        match config.key_info_server with
        | None -> Some ""
        | server when server = default_key_info_server -> None
        | server -> server in
      key_info_server_str |> if_some (Printf.fprintf ch "key_info_server = %s\n")
    )
  )
