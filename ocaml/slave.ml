(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install slave" command *)

open Options
open Support.Common

module Q = Support.Qdom
module J = Yojson.Basic
module JC = Zeroinstall.Json_connection

let handle options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  if args <> [] then raise (Support.Argparse.Usage_error 1);

  let connection = JC.json_connection ~from_peer:Lwt_io.stdin ~to_peer:Lwt_io.stdout in

  let do_select = function
    | [reqs; `Bool refresh] ->
        let requirements = reqs |> J.Util.member "interface" |> J.Util.to_string |> Zeroinstall.Requirements.default_requirements in
        let driver = Lazy.force options.driver in
        lwt (ready, results, _fp) = driver#solve_with_downloads requirements ~force:refresh ~update_local:refresh in
        let code, resp =
          if ready then
            ("ok", `String (Q.to_utf8 results#get_selections))
          else
            ("fail", `String (Zeroinstall.Diagnostics.get_failure_reason options.config results)) in
        `List [`String code; resp] |> Lwt.return
    | _ -> raise JC.Bad_request in

  connection#register_handler "select" do_select;

  let module V = Zeroinstall.Versions in
  let agreed_version = connection#invoke "select-api-version" [`String Zeroinstall.About.version]
  |> Lwt_main.run |> J.Util.to_string |> V.parse_version in

  if agreed_version < V.parse_version "2.5" then
    raise_safe "Minimum supported API version is 2.5"
  else if agreed_version > Zeroinstall.About.parsed_version then
    raise_safe "Maximum supported API version is %s" Zeroinstall.About.version;

  Lwt_main.run connection#run;
  log_info "OCaml slave exiting"
