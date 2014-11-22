(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A structure representing constraints/requirements specified by the user *)

open General
open Support.Common

type t = {
  interface_uri : iface_uri;
  command : string option;
  source : bool;
  extra_restrictions : string StringMap.t;  (* iface -> range *)
  os : string option;
  cpu : string option;
  message : string option;
  autocompile: bool option;
}

let default_requirements interface_uri = {
  interface_uri;
  command = Some "run";
  source = false;
  os = None;
  cpu = None;
  message = None;
  autocompile = None;
  extra_restrictions = StringMap.empty;
}

let parse_extra json : string StringMap.t =
  let open Yojson.Basic.Util in
  let add map (key, value) =
    StringMap.add key (to_string value) map in
  List.fold_left add StringMap.empty (to_assoc json)

let parse_requirements json =
  let open Yojson.Basic.Util in
  let to_string_option_or_empty x =
    match to_string_option x with
    | Some "" -> None
    | v -> v in
  try
    let alist = to_assoc json in
    let r = ref (default_requirements "") in
    let before = ref None in
    let not_before = ref None in
    ListLabels.iter alist ~f:(fun (key, value) ->
      match key with
      | "before" -> before := to_string_option_or_empty value
      | "not_before" -> not_before := to_string_option_or_empty value
      | "interface_uri" -> r := {!r with interface_uri = to_string value}
      | "command" -> r := {!r with command = to_string_option value}
      | "source" -> r := {!r with source = to_bool value}
      | "extra_restrictions" -> r := {!r with extra_restrictions = (parse_extra value)}
      | "os" -> r := {!r with os = to_string_option value}
      | "cpu" ->  r := {!r with cpu = to_string_option value}
      | "message" -> r := {!r with message = to_string_option value}
      | "compile" -> r := {!r with autocompile = Some (to_bool value)}
      | _ -> raise_safe "Unknown requirements field '%s'" key
    );

    if !r.interface_uri = "" then
      raise_safe "Missing 'interface_uri'";

    (* Update old before/not-before values *)
    let () = 
      let use expr =
        assert (!r.extra_restrictions = StringMap.empty);
        r := {!r with extra_restrictions = StringMap.singleton !r.interface_uri expr} in
      match !not_before, !before with
      | None, None -> ()
      | Some low, None -> use low
      | None, Some high -> use @@ "..!" ^ high
      | Some low, Some high -> use @@ low ^ "..!" ^ high in

    !r
  with Type_error (msg, _) ->
    raise_safe "Bad requirements JSON: %s" msg

let to_json reqs =
  let maybe name = function
    | None -> []
    | Some x -> [(name, `String x)] in
  let maybe_bool name = function
    | None -> []
    | Some x -> [(name, `Bool x)] in
  let {
    interface_uri; command; source;
    extra_restrictions; os; cpu;
    message; autocompile;
  } = reqs in
  `Assoc ([
    ("interface_uri", `String interface_uri);
    ("source", `Bool source);
    ("extra_restrictions", `Assoc (StringMap.map_bindings (fun k v -> (k, `String v)) extra_restrictions));
  ] @ List.concat [
    maybe "command" command;
    maybe "os" os;
    maybe "cpu" cpu;
    maybe "message" message;
    maybe_bool "compile" autocompile;
  ])

let load (system:system) path =
  let open Yojson.Basic in
  path |> system#with_open_in [Open_rdonly; Open_binary] (fun ch ->
    try parse_requirements (from_channel ~fname:path ch)
    with Safe_exception _ as ex -> reraise_with_context ex "... parsing JSON file %s" path
  )
