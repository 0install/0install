(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A structure representing constraints/requirements specified by the user *)

open General
open Support.Common

type requirements = {
  interface_uri : iface_uri;
  command : string option;
  source : bool;
  extra_restrictions : string StringMap.t;  (* iface -> range *)
  os : string option;
  cpu : string option;
  message : string option;
}

let default_requirements interface_uri = {
  interface_uri;
  command = Some "run";
  source = false;
  os = None;
  cpu = None;
  message = None;
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

let load (system:system) path =
  let open Yojson.Basic in
  system#with_open_in [Open_rdonly; Open_binary] 0 path (fun ch ->
    try parse_requirements (from_channel ~fname:path ch)
    with Safe_exception _ as ex -> reraise_with_context ex "... parsing JSON file %s" path
  )

(** Updates requirements based on command-line options.
    Handles --before, --not-before, --version and --version-for options.
    Existing requirements can be removed by setting the version to the empty string (e.g. --version="").
    @return the options list with all version specifiers removed and the updated restrictions. *)
let parse_restrictions options default_iface extra_restrictions =
  let open Options in

  (* Perhaps we should initialise these from [extra_restrictions], but the Python version doesn't. *)
  let before = ref None in
  let not_before = ref None in

  (** Handle --before, --not-before and --version by converting to --version-for options *)
  let options = Support.Argparse.filter_map_options options (function
    | Before v -> before := Some v; None
    | NotBefore v -> not_before := Some v; None
    | RequireVersion v -> Some (RequireVersionFor (default_iface, v))
    | x -> Some x
  ) in

  let version = match !not_before, !before with
  | None, None -> None
  | Some low, None -> Some low
  | None, Some high -> Some ("..!" ^ high)
  | Some "", Some "" -> Some "" (* Reset *)
  | Some low, Some high -> Some (low ^ "..!" ^ high) in

  let options = match version with
  | None -> options
  | Some v -> ("--version", (RequireVersionFor (default_iface, v))) :: options in

  (** Process --version-for options *)
  let r = ref extra_restrictions in

  (** TODO: later options override earlier ones; issue an error instead *)
  let process = function
    | RequireVersionFor (iface, "") -> r := StringMap.remove iface !r; None    (* TODO: check no error if already removed *)
    | RequireVersionFor (iface, expr) -> r := StringMap.add iface expr !r; None
    | x -> Some x in
  let options = Support.Argparse.filter_map_options options process in
  (options, !r)

(** Update the requirements based on the options (used for e.g. "0install update APP"). *)
let parse_update_options ?(update=true) options requirements =
  let open Options in

  let (options, new_restrictions) = parse_restrictions options requirements.interface_uri requirements.extra_restrictions in

  let r = ref {requirements with extra_restrictions = new_restrictions} in

  let empty_to_opt = function
    | "" -> None
    | s -> Some s in

  let options = Support.Argparse.filter_map_options options (function
    | WithMessage v    -> r := {!r with message = empty_to_opt v}; None
    | Cpu v            -> r := {!r with cpu = empty_to_opt v}; None
    | Os v             -> r := {!r with os = empty_to_opt v}; None
    | SelectCommand v  -> r := {!r with command = empty_to_opt v}; None
    | Source when not update -> r := {!r with source = true}; None
    | Source when !r.source -> None
    | Source ->
          (** Partly because it doesn't make much sense, and partly because you
              can't undo it, as there's no --not-source option. *)
          raise_safe "Can't update from binary to source type!"
    | x -> Some x
  ) in

  (options, !r)

let parse_options options interface_uri ~command =
  parse_update_options ~update:false options @@ {(default_requirements interface_uri) with command}

(** Convert a set of requirements to the corresponding command-line options. *)
let to_options requirements =
  let opt_arg opt_name = function
    | None -> []
    | Some value -> [opt_name; value] in

  let version_for (iface, expr) = ["--version-for"; iface; expr] in

  List.concat @@ [
    if requirements.source then ["--source"] else [];
    opt_arg "--message" requirements.message;
    opt_arg "--cpu" requirements.cpu;
    opt_arg "--os" requirements.os;
    ["--command"; default "" (requirements.command)];
  ] @ List.map version_for @@ StringMap.bindings requirements.extra_restrictions
