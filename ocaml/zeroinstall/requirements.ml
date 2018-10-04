(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
open Support.Common

type t = {
  interface_uri : Sigs.iface_uri;
  command : string option;
  source : bool;
  extra_restrictions : string XString.Map.t;  (* iface -> range *)
  os : Arch.os option;
  cpu : Arch.machine option;
  message : string option;
  may_compile : bool;
}

let run interface_uri = {
  interface_uri;
  command = Some "run";
  source = false;
  os = None;
  cpu = None;
  message = None;
  extra_restrictions = XString.Map.empty;
  may_compile = false;
}

let parse_extra json : string XString.Map.t =
  let open Yojson.Basic.Util in
  let add map (key, value) =
    XString.Map.add key (to_string value) map in
  List.fold_left add XString.Map.empty (to_assoc json)

let to_string_option_or_empty x =
  let open Yojson.Basic.Util in
  match to_string_option x with
  | Some "" -> None
  | v -> v

let parse_os x = to_string_option_or_empty x |> pipe_some Arch.parse_os
let parse_machine x = to_string_option_or_empty x |> pipe_some Arch.parse_machine

let of_json json =
  let open Yojson.Basic.Util in
  try
    let alist = to_assoc json in
    let r = ref (run "") in
    let before = ref None in
    let not_before = ref None in
    ListLabels.iter alist ~f:(fun (key, value) ->
      match key with
      | "before" -> before := to_string_option_or_empty value
      | "not_before" -> not_before := to_string_option_or_empty value
      | "interface_uri" -> r := {!r with interface_uri = to_string value}
      | "command" -> r := {!r with command = to_string_option value}
      | "source" -> r := {!r with source = to_bool value}
      | "may_compile" -> r := {!r with may_compile = to_bool value}
      | "extra_restrictions" -> r := {!r with extra_restrictions = (parse_extra value)}
      | "os" -> r := {!r with os = parse_os value}
      | "cpu" ->  r := {!r with cpu = parse_machine value}
      | "message" -> r := {!r with message = to_string_option value}
      | _ -> Safe_exn.failf "Unknown requirements field '%s'" key
    );

    if !r.interface_uri = "" then
      Safe_exn.failf "Missing 'interface_uri'";

    (* Update old before/not-before values *)
    let () = 
      let use expr =
        assert (!r.extra_restrictions = XString.Map.empty);
        r := {!r with extra_restrictions = XString.Map.singleton !r.interface_uri expr} in
      match !not_before, !before with
      | None, None -> ()
      | Some low, None -> use low
      | None, Some high -> use @@ "..!" ^ high
      | Some low, Some high -> use @@ low ^ "..!" ^ high in

    !r
  with Type_error (msg, _) ->
    Safe_exn.failf "Bad requirements JSON: %s" msg

let to_json reqs =
  let maybe name = function
    | None -> []
    | Some x -> [(name, `String x)] in
  let maybe_flag ~default name value =
    if value = default then [] else [(name, `Bool value)] in
  let {
    interface_uri; command; source;
    extra_restrictions; os; cpu;
    message; may_compile;
  } = reqs in
  `Assoc ([
    ("interface_uri", `String interface_uri);
  ] @ List.concat [
    maybe "command" command;
    maybe "os" (os |> map_some Arch.format_os);
    maybe "cpu" (cpu |> map_some Arch.format_machine);
    maybe "message" message;
    maybe_flag ~default:false "source" source;
    maybe_flag ~default:false "may_compile" may_compile;
    (if XString.Map.is_empty extra_restrictions
      then []
      else [(
        "extra_restrictions",
        `Assoc (XString.Map.map_bindings (fun k v -> (k, `String v)) extra_restrictions)
      )]);
  ])
