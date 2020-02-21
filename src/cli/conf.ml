(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install config" command *)

open Options
open Zeroinstall.General
open Support
open Support.Common

module U = Support.Utils
module C = Zeroinstall.Config

let minutes = 60.

type key =
  | Network_use
  | Freshness
  | Help_with_testing
  | Auto_approve_keys

let parse_bool s =
  match String.lowercase_ascii s with
  | "true" -> true
  | "false" -> false
  | _ -> Safe_exn.failf "Expected 'true' or 'false' but got '%s'" s

let parse_network_use = function
  | "full" -> Full_network
  | "minimal" -> Minimal_network
  | "off-line" -> Offline
  | other -> Safe_exn.failf "Invalid network use type '%s'" other

let parse_interval value =
  if value = "0" then 0.0 else (
    let l = String.length value in
    if l < 2 then
      Safe_exn.failf "Bad interval '%s' (use e.g. '7d')" value;
      let value, unt = String.sub value 0 (l - 1), XString.tail value (l - 1) in
      let value = try float_of_string value with Failure _ -> Safe_exn.failf "Invalid number '%s'" value in
      match unt with
      | "s" -> value
      | "m" -> value *. minutes
      | "h" -> value *. hours
      | "d" -> value *. days
      | _ -> Safe_exn.failf "Unknown unit '%s' - use e.g. 5d for 5 days" unt
  )

(* e.g. 120 -> "2m" *)
let format_interval interval =
  let time_units = [
    (60., "s");
    (60., "m");
    (24., "h");
  ] in
  let rec f v = function
    | [] -> (v, "d")
    | ((n, uname) :: us) ->
        if v < n then (v, uname)
        else f (v /. n) us in
  let (value, uname) = f interval time_units in
  if floor value = value then
    Printf.sprintf "%.0f%s" value uname
  else
    Printf.sprintf "%F%s" value uname

let parse_key = function
  | "network_use" -> Network_use
  | "freshness" -> Freshness
  | "help_with_testing" -> Help_with_testing
  | "auto_approve_keys" -> Auto_approve_keys
  | key -> Safe_exn.failf "Unknown setting name '%s'" key

let format_key = function
  | Network_use -> "network_use"
  | Freshness -> "freshness"
  | Help_with_testing -> "help_with_testing"
  | Auto_approve_keys -> "auto_approve_keys"

let format_setting config = function
  | Network_use -> C.format_network_use config.network_use
  | Freshness -> format_interval (default 0.0 config.freshness)
  | Help_with_testing -> C.format_bool config.help_with_testing
  | Auto_approve_keys -> C.format_bool config.auto_approve_keys

let set_setting config value = function
  | Network_use -> config.network_use <- parse_network_use value
  | Help_with_testing -> config.help_with_testing <- parse_bool value
  | Auto_approve_keys -> config.auto_approve_keys <- parse_bool value
  | Freshness ->
      let freshness = parse_interval value in
      config.freshness <- if freshness <= 0.0 then None else Some freshness

let show_settings config =
  [ Auto_approve_keys; Freshness; Help_with_testing; Network_use] |> List.iter (fun key ->
    Printf.printf "%s = %s\n" (format_key key) (format_setting config key)
  )

let handle options flags args =
  let tools = options.tools in
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  let config = options.config in
  match args with
  | [] ->
      begin match tools#ui#show_preferences with
      | None -> show_settings config
      | Some box -> Lwt_main.run box end
  | [key] -> format_setting config (parse_key key) |> print_endline
  | [key; value] -> set_setting config value (parse_key key); Zeroinstall.Config.save_config config
  | _ -> raise (Support.Argparse.Usage_error 1)
