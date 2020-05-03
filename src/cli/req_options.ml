(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A structure representing constraints/requirements specified by the user *)

open Options
open Support
open Support.Common
open Zeroinstall.Requirements

(** Updates requirements based on command-line options.
    Handles --before, --not-before, --version and --version-for options.
    Existing requirements can be removed by setting the version to the empty string (e.g. --version="").
    @return the options list with all version specifiers removed and the updated restrictions. *)
let parse_restrictions options default_iface extra_restrictions =
  (* Perhaps we should initialise these from [extra_restrictions], but the Python version doesn't. *)
  let before = ref None in
  let not_before = ref None in

  (* Handle --before, --not-before and --version by converting to --version-for options *)
  let options = options |> List.filter_map (function
    | `Before v -> before := Some v; None
    | `NotBefore v -> not_before := Some v; None
    | `RequireVersion v -> Some (`RequireVersionFor (default_iface, v))
    | `RequireVersionFor _ as r -> Some r
  ) in

  let version = match !not_before, !before with
  | None, None -> None
  | Some low, None -> Some (low ^ "..")
  | None, Some high -> Some ("..!" ^ high)
  | Some "", Some "" -> Some "" (* Reset *)
  | Some low, Some high -> Some (low ^ "..!" ^ high) in

  let options = match version with
  | None -> options
  | Some v -> `RequireVersionFor (default_iface, v) :: options in

  (* Process --version-for options *)
  let r = ref extra_restrictions in

  (* TODO: later options override earlier ones; issue an error instead *)
  let process = function
    | `RequireVersionFor (iface, "") -> r := XString.Map.remove iface !r    (* TODO: check no error if already removed *)
    | `RequireVersionFor (iface, expr) -> r := XString.Map.add iface expr !r in
  List.iter process options;
  !r

(** Update the requirements based on the options (used for e.g. "0install update APP"). *)
let parse_update_options ?(update=true) options requirements =
  let restriction_options = ref [] in
  let select_options = ref [] in
  ListLabels.iter options ~f:(function
    | #version_restriction_option as o -> restriction_options := o :: !restriction_options
    | #other_req_option | `MayCompile as o -> select_options := o :: !select_options
  );
  let new_restrictions = parse_restrictions !restriction_options requirements.interface_uri requirements.extra_restrictions in

  let r = ref {requirements with extra_restrictions = new_restrictions} in

  let empty_to_opt = function
    | "" -> None
    | s -> Some s in

  ListLabels.iter !select_options ~f:(function
    | `WithMessage v    -> r := {!r with message = empty_to_opt v}
    | `Cpu v            -> r := {!r with cpu = empty_to_opt v |> pipe_some Zeroinstall.Arch.parse_machine}
    | `Os v             -> r := {!r with os = empty_to_opt v |> pipe_some Zeroinstall.Arch.parse_os}
    | `SelectCommand v  -> r := {!r with command = empty_to_opt v}
    | `MayCompile       -> r := {!r with may_compile = true}
    | `Source when not update -> r := {!r with source = true}
    | `Source when !r.source -> ()
    | `Source ->
          (* Partly because it doesn't make much sense, and partly because you
             can't undo it, as there's no --not-source option. *)
          Safe_exn.failf "Can't update from binary to source type!"
  );

  !r

let parse_options options interface_uri ~command =
  parse_update_options ~update:false options @@ {(run interface_uri) with command}

(** Convert a set of requirements to the corresponding command-line options. *)
let to_options requirements =
  let opt_arg opt_name = function
    | None -> []
    | Some value -> [opt_name; value] in

  let version_for (iface, expr) = ["--version-for"; iface; expr] in

  List.concat @@ [
    if requirements.source then ["--source"] else [];
    opt_arg "--message" requirements.message;
    opt_arg "--cpu" (requirements.cpu |> map_some Zeroinstall.Arch.format_machine);
    opt_arg "--os" (requirements.os |> map_some Zeroinstall.Arch.format_os);
    ["--command"; default "" (requirements.command)];
  ] @ List.map version_for @@ XString.Map.bindings requirements.extra_restrictions
