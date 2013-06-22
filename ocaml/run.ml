(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Executing a selections document *)

open Constants;;
open Support;;

let re_exec_name = Str.regexp "^[^./'][^/']*$";;

let validate_exec_name name =
  if Str.string_match re_exec_name name 0 then
    ()
  else
    raise_safe ("Invalid name in executable binding: " ^ name)

let ensure_runenv config =
  let main_dir = Basedir.save_path ("0install.net" +/ "injector") config.Config.basedirs.Basedir.cache in
  let runenv = main_dir +/ "runenv.native" in
  if Sys.file_exists runenv then
    ()
  else
    Unix.symlink (config.Config.resource_dir +/ "runenv.native") runenv
;;

let do_exec_binding config env impls = function
  | (iface_uri, Binding.ExecutableBinding {Binding.exec_type; Binding.name; Binding.command}) -> (
    validate_exec_name name;

    (* set up launcher symlink *)
    let exec_dir = Basedir.save_path ("0install.net" +/ "injector" +/ "executables" +/ name) config.Config.basedirs.Basedir.cache in
    let exec_path = exec_dir ^ Filename.dir_sep ^ name in   (* TODO: windows *)

    if not (Sys.file_exists exec_path) then (
      (* TODO: windows *)
      Unix.symlink "../../runenv.native" exec_path;
      Unix.chmod exec_dir 0o500
    ) else ();

    let command_argv = Command.build_command impls iface_uri command env in

    let () = match exec_type with
    | Binding.InPath -> Binding.prepend "PATH" exec_dir path_sep env
    | Binding.InVar -> Env.putenv name exec_path env in

    let open Yojson.Basic in
    let json :json = `List (List.map (fun a -> `String a) command_argv) in

    Env.putenv ("0install-runenv-" ^ name) (to_string json) env
  )
  | _ -> ()
;;

(* Make a map from InterfaceURIs to the selected <selection> and (for non-native packages) paths *)
let make_selection_map stores sels =
  let add_selection m sel =
    let path = Selections.get_path stores sel in
    let value = (sel, path) in
    StringMap.add (ZI.get_attribute "interface" sel) value m
  in ZI.fold_left add_selection StringMap.empty sels "selection"
;;

let execute_selections sels args config =
  let env = Env.copy_current_env () in
  let impls = make_selection_map config.Config.stores sels in
  let bindings = Binding.collect_bindings impls sels in

  ensure_runenv config;

  (* Do <environment> bindings *)
  List.iter (Binding.do_env_binding env impls) bindings;

  (* Do <executable-in-*> bindings *)
  List.iter (do_exec_binding config env impls) bindings;

  let command = ZI.get_attribute "command" sels in
  let prog_args = (Command.build_command impls (ZI.get_attribute "interface" sels) command env) @ args in
  flush stdout;
  flush stderr;
  Unix.execve (List.hd prog_args) (Array.of_list prog_args) (Env.to_array env);;
