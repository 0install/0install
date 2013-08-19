(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** High-level helper functions *)

open Support.Common
module Basedir = Support.Basedir
module U = Support.Utils
module Qdom = Support.Qdom

type select_mode =
  | Select_only       (* only download feeds, not archives; display "Select" in GUI *)
  | Download_only     (* download archives too; refresh if stale feeds; display "Download" in GUI *)
  | Select_for_run    (* download archives; update stale in background; display "Run" in GUI *)
  | Select_for_update (* like Download_only, but save changes to apps *)

let string_of_ynm = function
  | Yes -> "yes"
  | No -> "no"
  | Maybe -> "maybe"

(** Get some selectsions for these requirements. *)
let solve_and_download_impls (slave:Python.slave) reqs mode ~refresh ~use_gui =
  let action = match mode with
  | Select_only -> "for-select"
  | Download_only | Select_for_update -> "for-download"
  | Select_for_run -> "for-run" in

  let opts = `Assoc [
    ("refresh", `Bool refresh);
    ("use_gui", `String (string_of_ynm use_gui));
  ] in

  let read_xml = function
    | `String "Aborted" -> None
    | `String s -> Some (Qdom.parse_input None @@ Xmlm.make_input (`String (0, s)))
    | _ -> raise_safe "Invalid response" in
  let request : Yojson.Basic.json = `List [`String "select"; `String action; opts; Requirements.to_json reqs] in

  slave#invoke request read_xml

(** Ensure all selections are cached, downloading any that are missing.
    If [distro] is given then distribution packages are also installed, otherwise
    they are ignored. *)
let download_selections config distro sels =
  if Selections.get_unavailable_selections config ?distro sels <> [] then (
    let opts = `Assoc [
      ("include-packages", `Bool (distro <> None));
    ] in

    let request : Yojson.Basic.json = `List [`String "download-selections"; opts] in

    U.finally (fun slave -> slave#close) (new Python.slave config) (fun slave ->
      slave#invoke ~xml:sels request ignore
    )
  )
