(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** <command> elements *)

open General
open Support.Common
module Qdom = Support.Qdom
module U = Support.Utils

let get_command name elem =
  let is_command node = ((ZI.tag node = Some "command") && (ZI.get_attribute "name" node = name)) in
  match Qdom.find is_command elem with
  | Some command -> command
  | None -> Qdom.raise_elem "No <command> with name '%s' in" name elem

let re_template = Str.regexp ("\\$\\(\\$\\|\\([a-zA-Z_][a-zA-Z0-9_]*\\)\\|{[^}]*}\\)")

(* Perform $ substitutions on [template], taking values from [env] *)
let expand_arg arg env =
  (* Some versions of Python add newlines inside the <arg> element. *)
  let template = trim arg.Qdom.last_text_inside in
  let remove_braces s =
    let l = String.length s in
    if s.[0] = '{' then (
      assert (s.[l - 1] = '}');
      String.sub s 1 (l - 2)
    ) else s; in
  let expand s = match (Str.matched_group 1 s) with
  | "$" -> "$"
  | "" | "{}" -> Qdom.raise_elem "Empty variable name in template '%s' in" template arg
  | m -> Env.find (remove_braces m) env in
  Str.global_substitute re_template expand template
;;

(* Return a list of string arguments by expanding <arg> and <for-each> children of [elem] *)
let get_args elem env =
  let rec get_args_loop elem =
    let process child args = match ZI.tag child with
    | Some "arg" -> (expand_arg child env) :: args
    | Some "for-each" -> (expand_foreach child env) @ args
    | _ -> args in
    List.fold_right process (elem.Qdom.child_nodes) []
  and expand_foreach node env =
    let item_from = ZI.get_attribute "item-from" node in
    let separator = default path_sep (ZI.get_attribute_opt "separator" node) in
    match Env.find_opt item_from env with
    | None -> []
    | Some source ->
        let rec loop = function
          | [] -> []
          | x::xs ->
              let old = Env.find_opt "item" env in
              let () = Env.putenv "item" x env in
              let new_args = get_args_loop node in
              let () = match old with
              | None -> ()
              | Some v -> Env.putenv "item" v env in
              new_args @ (loop xs) in
        loop (Str.split_delim (Str.regexp_string separator) source)
  in get_args_loop elem
;;

let get_runner elem =
  match ZI.map ~f:(fun a -> a) elem "runner" with
    | [] -> None
    | [runner] -> Some runner
    | _ -> Qdom.raise_elem "Multiple <runner>s in " elem
;;

(* Build up the argv array to execute this command.
   In --dry-run mode, don't complain if the target doesn't exist. *)
let rec build_command ?main ?(dry_run=false) impls command_iface command_name env : string list =
  try
    let (command_sel, command_impl_path) = Selections.find_ex command_iface impls in
    let command = get_command command_name command_sel in
    let command_rel_path =
      let path = ZI.get_attribute_opt "path" command in
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
              if (Filename.is_relative  command_rel_path) then
                Qdom.raise_elem ("Relative 'path' in ") command
              else
                command_rel_path      
            )
            | Some dir -> (
              if (Filename.is_relative command_rel_path) then
                Filename.concat dir command_rel_path
              else
                Qdom.raise_elem "Absolute path '%s' in" command_rel_path command
            )
          in
            if Sys.file_exists command_path || dry_run then
              command_path :: command_args
            else if on_windows && Sys.file_exists (command_path ^ ".exe") then
              (command_path ^ ".exe") :: command_args
            else
              Qdom.raise_elem "Path '%s' does not exist: see" command_path command
    ) in

    (* recursively process our runner, if any *)
    match get_runner command with
    | None -> (
        if command_rel_path = None then
          Qdom.raise_elem "Missing 'path' on command with no <runner>: " command
        else
          args
      )
    | Some runner ->
        let runner_args = get_args runner env in
        let runner_command_name = default "run" (ZI.get_attribute_opt "command" runner) in
        (build_command ~dry_run impls (ZI.get_attribute "interface" runner) runner_command_name env) @ runner_args @ args
  with Safe_exception _ as ex -> reraise_with_context ex "... building command for %s" command_iface
;;
