(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Binding elements: <environment>, <executable-in-*>, <binding> *)

open Support
open Support.Common

type which_end = Prepend | Append
type add_mode = {pos :which_end; default :string option; separator :string}

type mode =
  | Add of add_mode
  | Replace

type env_source =
  | InsertPath of filepath
  | Value of string

type exec_type = InPath | InVar
type env_binding = {var_name: Env.name; mode: mode; source: env_source}
type exec_binding = {exec_type: exec_type; name: string; command: string}

type binding =
| EnvironmentBinding of env_binding
| ExecutableBinding of exec_binding
| GenericBinding of [`Binding] Element.t

let get_source b =
  match (Element.insert b, Element.value b) with
  | (None, None) -> Element.raise_elem "Missing 'insert' or 'value' on " b
  | (Some i, None) -> InsertPath i
  | (None, Some v) -> Value v
  | (Some _, Some _) -> Element.raise_elem "Can't use 'insert' and 'value' together on " b

let get_mode b =
  match default "prepend" (Element.mode b) with
  | "prepend" -> Add {pos = Prepend; default = Element.default b; separator = default path_sep (Element.separator b)}
  | "append" -> Add {pos = Append; default = Element.default b; separator = default path_sep (Element.separator b)}
  | "replace" -> Replace
  | x -> Element.raise_elem "Unknown mode '%s' on" x b

let is_binding = function
  | "environment" | "executable-in-path" | "executable-in-var" | "overlay" | "binding" -> true
  | _ -> false

let parse_binding = function
  | `Environment b -> EnvironmentBinding {var_name = Element.binding_name b; mode = get_mode b; source = get_source b}
  | `Executable_in_path b -> ExecutableBinding {exec_type = InPath; name = Element.binding_name b; command = default "run" (Element.command b)}
  | `Executable_in_var b -> ExecutableBinding {exec_type = InVar; name = Element.binding_name b; command = default "run" (Element.command b)}
  | `Binding b -> GenericBinding b

(** Return the name of the command needed by this binding, if any. *)
let get_command = function
  | EnvironmentBinding _ -> None
  | ExecutableBinding {command; _} -> Some command
  | GenericBinding elem -> Element.command elem

let get_default name = match name with
  | "PATH" -> Some "/bin:/usr/bin"
  | "XDG_CONFIG_DIRS" -> Some "/etc/xdg"
  | "XDG_DATA_DIRS" -> Some "/usr/local/share:/usr/share"
  | _ -> None

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
    match Env.get name env with
      | Some v -> add_to v                  (* add to current value of variable *)
      | None -> match default with
        | Some d -> add_to d                (* or to the specified default *)
        | None -> match get_default name with    
          | Some d -> add_to d              (* or to the standard default *)
          | None ->
              log_info "%s=%s" name value;  (* no old value; use new value directly *)
              value

let do_env_binding env sel {var_name; mode; source} =
  let add value = env := Env.put var_name (calc_new_value var_name mode value !env) !env in
  match source with
  | Value v -> add v
  | InsertPath i -> match Lazy.force sel with
    | (_, None) -> ()  (* a PackageSelection; skip binding *)
    | (_, Some p) -> add (p +/ i)

let prepend name value separator env =
  let mode = Add {pos = Prepend; default = None; separator} in
  env := Env.put name (calc_new_value name mode value !env) !env
