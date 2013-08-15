(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Binding elements: <environment>, <executable-in-*>, <binding> *)

open General
open Support.Common
module Qdom = Support.Qdom

type which_end = Prepend | Append;;
type add_mode = {pos :which_end; default :string option; separator :string};;

type mode =
  | Add of add_mode
  | Replace;;

type env_source =
  | InsertPath of filepath
  | Value of string;;

type exec_type = InPath | InVar;;
type env_binding = {var_name: varname; mode: mode; source: env_source};;
type exec_binding = {exec_type: exec_type; name: string; command: string};;

type binding =
| EnvironmentBinding of env_binding
| ExecutableBinding of exec_binding
| GenericBinding of Qdom.element

let get_source b =
  let get name = ZI.get_attribute_opt name b in
  match (get "insert", get "value") with
  | (None, None) -> Qdom.raise_elem "Missing 'insert' or 'value' on " b
  | (Some i, None) -> InsertPath i
  | (None, Some v) -> Value v
  | (Some _, Some _) -> Qdom.raise_elem "Can't use 'insert' and 'value' together on " b
;;

let get_mode b =
  let get name = ZI.get_attribute_opt name b in
  match default "prepend" (get "mode") with
  | "prepend" -> Add {pos = Prepend; default = get "default"; separator = default path_sep (get "separator")}
  | "append" -> Add {pos = Append; default = get "default"; separator = default path_sep (get "separator")}
  | "replace" -> Replace
  | x -> Qdom.raise_elem "Unknown mode '%s' on" x b
;;

let is_binding = function
  | "environment" | "executable-in-path" | "executable-in-var" | "overlay" | "binding" -> true
  | _ -> false

let parse_binding elem =
  let get_opt name = ZI.get_attribute_opt name elem in
  let get name = ZI.get_attribute name elem in
  match ZI.tag elem with
  | Some "environment" -> Some (EnvironmentBinding {var_name = get "name"; mode = get_mode elem; source = get_source elem})
  | Some "executable-in-path" -> Some (ExecutableBinding {exec_type = InPath; name = get "name"; command = default "run" (get_opt "command")})
  | Some "executable-in-var" -> Some (ExecutableBinding {exec_type = InVar; name = get "name"; command = default "run" (get_opt "command")})
  | Some "overlay" -> Some (GenericBinding elem)
  | Some "binding" -> Some (GenericBinding elem)
  | _ -> None

(** Return the name of the command needed by this binding, if any. *)
let get_command = function
  | EnvironmentBinding _ -> None
  | ExecutableBinding {command; _} -> Some command
  | GenericBinding elem -> ZI.get_attribute_opt "command" elem

(* Return all bindings in document order *)
let collect_bindings impls root =
  let bindings = ref [] in

  let rec process ~deps ~commands iface parent =
    let process_child node =
      match ZI.tag node with
      | Some "requires" | Some "runner" when deps ->
          let dep_iface = ZI.get_attribute "interface" node in
          if StringMap.mem dep_iface impls then process ~deps:false ~commands:false dep_iface node
          else ()
      | Some "command" when commands -> process ~deps:true ~commands:false iface node
      | _ -> match parse_binding node with
             | None -> ()
             | Some binding -> bindings := (iface, binding) :: !bindings in
    ZI.iter ~f:process_child parent in

  let process_sel node =
    let iface = (ZI.get_attribute "interface" node) in
    try process ~deps:true ~commands:true iface node
    with Safe_exception _ as ex -> reraise_with_context ex "... getting bindings from selection %s" iface
  in 
  ZI.iter_with_name ~f:process_sel root "selection";
  List.rev !bindings
;;

let get_default name = match name with
  | "PATH" -> Some "/bin:/usr/bin"
  | "XDG_CONFIG_DIRS" -> Some "/etc/xdg"
  | "XDG_DATA_DIRS" -> Some "/usr/local/share:/usr/share"
  | _ -> None
;;

let calc_new_value name mode value env =
  match mode with
  | Replace ->
      log_info "%s=%s" name value;
      value
  | Add {pos; default; separator} ->
    let add_to old = match pos with
      | Prepend ->
          log_info "%s=%s%s..." name value separator;
          value ^ separator ^ old
      | Append ->
          log_info "%s=...%s%s" name separator value;
          old ^ separator ^ value in
    match Env.find_opt name env with
      | Some v -> add_to v                  (* add to current value of variable *)
      | None -> match default with
        | Some d -> add_to d                (* or to the specified default *)
        | None -> match get_default name with    
          | Some d -> add_to d              (* or to the standard default *)
          | None -> value                   (* no old value; use new value directly *)
;;

let do_env_binding env impls iface {var_name; mode; source} =
  let add value = Env.putenv var_name (calc_new_value var_name mode value env) env in
  match source with
  | Value v -> add v
  | InsertPath i -> match StringMap.find iface impls with
    | (_, None) -> ()  (* a PackageSelection; skip binding *)
    | (_, Some p) -> add (p +/ i)

let prepend name value separator env =
  let mode = Add {pos = Prepend; default = None; separator} in
  Env.putenv name (calc_new_value name mode value env) env
;;
