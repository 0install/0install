(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** <command> elements *)

open Support.Common
module Q = Support.Qdom
module U = Support.Utils

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
  | m -> Env.get_exn env (remove_braces m) in
  Str.global_substitute re_template expand template

type arg_parent = [`Command | `Runner | `For_each] Element.t

(* Return a list of string arguments by expanding <arg> and <for-each> children of [elem] *)
let get_args elem env =
  let rec get_args_loop elem =
    List.fold_right (fun child args ->
      match child with
      | `Arg child -> (expand_arg child env) :: args
      | `For_each child -> (expand_foreach child env) @ args
    ) (Element.arg_children elem) []
  and expand_foreach node env =
    let item_from = Element.item_from node in
    let separator = default path_sep (Element.separator node) in
    match Env.get env item_from with
    | None -> []
    | Some source ->
        let rec loop = function
          | [] -> []
          | x::xs ->
              let old = Env.get env "item" in
              Env.put env "item" x;
              let new_args = get_args_loop (node :> arg_parent) in
              old |> if_some (Env.put env "item");
              new_args @ (loop xs) in
        loop (Str.split_delim (Str.regexp_string separator) source)
  in get_args_loop (elem :> arg_parent)

let find_ex role impls =
  Selections.RoleMap.find role impls
  |? lazy (raise_safe "Missing a selection for role '%s'" (Selections.Role.to_string role))

(* Build up the argv array to execute this command.
   In --dry-run mode, don't complain if the target doesn't exist. *)
let rec build_command ?main ?(dry_run=false) impls req env : string list =
  try
    let (command_sel, command_impl_path) = find_ex req.Selections.role impls in
    let command =
      match req.Selections.command with
      | None -> Element.make_command ~source_hint:(Some command_sel) "run"
      | Some command_name -> Element.get_command_ex command_name command_sel in
    let command_rel_path =
      let path = Element.path command in
      match main, path with
      | None, path -> path
      | Some main, _ when (U.starts_with main "/") -> Some (U.string_tail main 1)   (* --main=/foo *)
      | Some main, Some path -> Some (Filename.dirname path +/ main)                (* --main=foo *)
      | Some main, None -> raise_safe "Can't use a relative replacement main (%s) when there is no original one!" main in

    (* args for the first command *)
    let command_args = get_args command env in
    let args = (match command_rel_path with
      | None -> command_args
      | Some command_rel_path ->
          let command_path =
            match command_impl_path with
            | None -> (   (* PackageSelection *)
              if Filename.is_relative command_rel_path then
                Element.raise_elem "Relative 'path' in " command
              else
                command_rel_path
            )
            | Some dir -> (
              if Filename.is_relative command_rel_path then
                Filename.concat dir command_rel_path
              else
                Element.raise_elem "Absolute path '%s' in" command_rel_path command
            )
          in
            if Sys.file_exists command_path || dry_run then
              command_path :: command_args
            else if on_windows && Sys.file_exists (command_path ^ ".exe") then
              (command_path ^ ".exe") :: command_args
            else
              Element.raise_elem "Path '%s' does not exist: see" command_path command
    ) in

    (* recursively process our runner, if any *)
    match Element.get_runner command with
    | None -> (
        if command_rel_path = None then
          Element.raise_elem "Missing 'path' on command with no <runner>: " command
        else
          args
      )
    | Some runner ->
        let runner_args = get_args runner env in
        let runner_command_name = default "run" (Element.command runner) in
        (* note: <runner> is always binary *)
        let runner_role = {Selections.iface = Element.interface runner; source = false} in
        let runner_req = {Selections.command = Some runner_command_name; role = runner_role} in
        (build_command ~dry_run impls runner_req env) @ runner_args @ args
  with Safe_exception _ as ex -> reraise_with_context ex "... building command for %s" (Selections.(Role.to_string req.role))
