(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Executing a selections document *)

open General;;

let re_exec_name = Str.regexp "^[^./'][^/']*$";;

let validate_exec_name name =
  if Str.string_match re_exec_name name 0 then
    ()
  else
    raise_safe ("Invalid name in executable binding: " ^ name)

let ensure_runenv config =
  let main_dir = Basedir.save_path config.system ("0install.net" +/ "injector") config.basedirs.Basedir.cache in
  let runenv = main_dir +/ "runenv" in
  if Sys.file_exists runenv then
    ()
  else
    (** TODO: If abspath_0install is a native binary, we could avoid starting a shell here. *)
    let write handle =
      output_string handle (Printf.sprintf "#!/bin/sh\nexec '%s' runenv \"$0\" \"$@\"\n" config.abspath_0install)
    in config.system#atomic_write write runenv 0o755
;;

let do_exec_binding config env impls = function
  | (iface_uri, Binding.ExecutableBinding {Binding.exec_type; Binding.name; Binding.command}) -> (
    validate_exec_name name;

    (* set up launcher symlink *)
    let exec_dir = Basedir.save_path config.system ("0install.net" +/ "injector" +/ "executables" +/ name) config.basedirs.Basedir.cache in
    let exec_path = exec_dir ^ Filename.dir_sep ^ name in   (* TODO: windows *)

    if not (Sys.file_exists exec_path) then (
      if Support.on_windows then (
        let write handle =
          (* TODO: escaping *)
          output_string handle (Printf.sprintf "\"%s\" runenv %0 %*\n" config.abspath_0install)
        in config.system#atomic_write write exec_path 0o755
      ) else (
        Unix.symlink "../../runenv" exec_path
      );
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
  let impls = make_selection_map config.stores sels in
  let bindings = Binding.collect_bindings impls sels in

  ensure_runenv config;

  (* Do <environment> bindings *)
  List.iter (Binding.do_env_binding env impls) bindings;

  (* Do <executable-in-*> bindings *)
  List.iter (do_exec_binding config env impls) bindings;

  let command = ZI.get_attribute "command" sels in
  let prog_args = (Command.build_command impls (ZI.get_attribute "interface" sels) command env) @ args in
  config.system#exec prog_args ~env:(Env.to_array env)
;;

(** This is called in a new process by the launcher created by [ensure_runenv]. *)
let runenv args =
  match args with
  | [] -> failwith "No args passed to runenv!"
  | arg0::args ->
    try
      let var = "0install-runenv-" ^ Filename.basename arg0 in
      let s = Support.getenv_ex var in
      let open Yojson.Basic in
      let envargs = Util.convert_each Util.to_string (from_string s) in
      let system = new System.real_system in
      system#exec (envargs @ args)
    with Safe_exception _ as ex -> reraise_with_context ex ("... launching " ^ arg0)
;;
