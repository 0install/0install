(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
open Support.Common

let re_template = Str.regexp ("\\$\\(\\$\\|\\([a-zA-Z_][a-zA-Z0-9_]*\\)\\|{[^}]*}\\)")

(* Perform $ substitutions on [template], taking values from [env] *)
let expand_arg arg env =
  (* Some versions of Python add newlines inside the <arg> element. *)
  let template = String.trim (Element.simple_content arg) in
  let remove_braces s =
    let l = String.length s in
    if s.[0] = '{' then (
      assert (s.[l - 1] = '}');
      String.sub s 1 (l - 2)
    ) else s; in
  let expand s = match (Str.matched_group 1 s) with
  | "$" -> "$"
  | "" | "{}" -> Element.raise_elem "Empty variable name in template '%s' in" template arg
  | m -> Env.get_exn (remove_braces m) env in
  Str.global_substitute re_template expand template

(* [values ~env node] is the list of values to iterate over for <for-each> element [node]. *)
let values ~env node =
  match Env.get (Element.item_from node) env with
  | None -> []
  | Some source ->
    let separator = default path_sep (Element.separator node) in
    Str.split_delim (Str.regexp_string separator) source

let ( >>= ) x f = List.concat (List.map f x)

(* Expand an <arg> or <for-each> element to a list of arguments. *)
let rec expand ~env = function
  | `Arg node ->
    [expand_arg node env]
  | `For_each node ->
    let specs = Element.arg_children node in
    values ~env node >>= fun value ->
    specs >>= fun spec ->
    expand spec ~env:(Env.put "item" value env)

let get_args elem env =
  try
    Element.arg_children elem >>= expand ~env
  with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... expanding %a" Element.pp elem

let find_ex role impls =
  Selections.RoleMap.find_opt role impls
  |? lazy (Safe_exn.failf "Missing a selection for role '%a'" Selections.Role.pp role)

(* [command_rel_path command] is the "path" attribute on the <command> element, if any.
   If [main] is given, this overrides the path. *)
let command_rel_path ?main command =
  let path = Element.path command in
  match main, path with
  | None, path -> path
  | Some main, _ when XString.starts_with main "/" -> Some (XString.tail main 1)   (* --main=/foo *)
  | Some main, Some path -> Some (Filename.dirname path +/ main)              (* --main=foo *)
  | Some main, None -> Safe_exn.failf "Can't use a relative replacement main (%s) when there is no original one!" main

(* The absolute path of the executable to run for <command>, if any (ignoring any <runner>). *)
let command_exe ?main ~dry_run ~impl_path command =
  match command_rel_path ?main command with
  | None -> None
  | Some path -> (* Make it absolute *)
    let command_path =
      match impl_path, Filename.is_relative path with
      | Some dir, true -> Filename.concat dir path  (* 0install impl *)
      | None,    false -> path                      (* PackageSelection *)
      | Some _,  false -> Element.raise_elem "Absolute path '%s' in" path command
      | None,     true -> Element.raise_elem "Relative 'path' in " command
    in
    if Sys.file_exists command_path || dry_run then
      Some command_path
    else if on_windows && Sys.file_exists (command_path ^ ".exe") then
      Some (command_path ^ ".exe")
    else
      Element.raise_elem "Path '%s' does not exist: see" command_path command

let ( @? ) x xs =
  match x with
  | None -> xs
  | Some x -> x :: xs

let rec build_command ?main ?(dry_run=false) impls req env : string list =
  let {Selections.command; role} = req in
  try
    let (command_sel, impl_path) = find_ex role impls in
    let command =
      match command with
      | None -> Element.make_command ~source_hint:(Some command_sel) "run"
      | Some command_name -> Element.get_command_ex command_name command_sel in
    let command_exe = command_exe ?main ~dry_run ~impl_path command in
    (* args for the first command *)
    let command_args = get_args command env in
    let args = command_exe @? command_args in
    (* recursively process our runner, if any *)
    match Element.get_runner command with
    | None when command_exe = None ->
      Element.raise_elem "Missing 'path' on command with no <runner>: " command
    | None ->
      args
    | Some runner ->
      let runner_args = get_args runner env in
      let runner_command_name = Element.command runner |> default "run" in
      (* note: <runner> is always binary *)
      let runner_role = {Selections.iface = Element.interface runner; source = false} in
      let runner_req = {Selections.command = Some runner_command_name; role = runner_role} in
      build_command ~dry_run impls runner_req env @ runner_args @ args
  with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... building command for %a" Selections.Role.pp role
