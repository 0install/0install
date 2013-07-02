(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Executing a selections document *)

open General
open Support.Common
module Basedir = Support.Basedir

let re_exec_name = Str.regexp "^[^./'][^/']*$";;

let validate_exec_name name =
  if Str.string_match re_exec_name name 0 then
    ()
  else
    raise_safe "Invalid name in executable binding: %s" name

class virtual launcher_builder config script =
  let hash = String.sub (Digest.to_hex @@ Digest.string script) 0 6 in
  object
    method make_dir name =
      Basedir.save_path config.system ("0install.net" +/ "injector" +/ ("exec-" ^ hash) +/ name) config.basedirs.Basedir.cache

    method add_launcher path =
      if not @@ Sys.file_exists path then (
        let write ch = output_string ch script in
        config.system#atomic_write write path 0o755
      )
  end

(** If abspath_0install is a native binary, we can avoid starting a shell here. *)
class native_launcher_builder config =
  let script = Printf.sprintf "#!%s runenv\n" config.abspath_0install in
  object (_ : #launcher_builder)
    inherit launcher_builder config script
  end

(** We can't use interpreted bytecode as a #! interpreter, so use a shell script instead. *)
class bytecode_launcher_builder config =
  let script = Printf.sprintf "#!/bin/sh\nexec '%s' runenv \"$0\" \"$@\"\n" config.abspath_0install in
  object (_ : #launcher_builder)
    inherit launcher_builder config script
  end

(* TODO: untested; escaping probably doesn't work.
   Other options here are the C# launcher (rather slow) or a C launcher of some description. *)
class windows_launcher_builder config =
  let script = Printf.sprintf "\"%s\" runenv %0 %*\n" config.abspath_0install in
  object (_ : #launcher_builder)
    inherit launcher_builder config script
  end

let get_launcher_builder config =
  if on_windows then new windows_launcher_builder config
  else
    let buf = String.create 2 in
    let () = config.system#with_open (fun ch -> really_input ch buf 0 2) config.abspath_0install in
    if buf = "!#" then
      new bytecode_launcher_builder config
    else
      new native_launcher_builder config

let do_exec_binding builder env impls = function
  | (iface_uri, Binding.ExecutableBinding {Binding.exec_type; Binding.name; Binding.command}) -> (
    validate_exec_name name;

    let exec_dir = builder#make_dir name in
    let exec_path = exec_dir +/ name in
    builder#add_launcher exec_path;
    Unix.chmod exec_dir 0o500;

    let command_argv = Command.build_command impls iface_uri command env in

    let () = match exec_type with
    | Binding.InPath -> Binding.prepend "PATH" exec_dir path_sep env
    | Binding.InVar -> Env.putenv name exec_path env in

    let open Yojson.Basic in
    let json :json = `List (List.map (fun a -> `String a) command_argv) in

    Env.putenv ("zeroinstall-runenv-" ^ name) (to_string json) env
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

(** Calculate the arguments and environment to pass to exec to run this
    process. This also ensures any necessary launchers exist, creating them
    if not. *)
let get_exec_args config sels args =
  let env = Env.copy_current_env () in
  let impls = make_selection_map config.stores sels in
  let bindings = Binding.collect_bindings impls sels in
  let launcher_builder = get_launcher_builder config in

  (* Do <environment> bindings *)
  List.iter (Binding.do_env_binding env impls) bindings;

  (* Do <executable-in-*> bindings *)
  List.iter (do_exec_binding launcher_builder env impls) bindings;

  let command = ZI.get_attribute "command" sels in
  let prog_args = (Command.build_command impls (ZI.get_attribute "interface" sels) command env) @ args in

  (prog_args, (Env.to_array env))
;;

let execute_selections config sels args ?wrapper =
  let (prog_args, env) = get_exec_args config sels args in

  let prog_args =
    match wrapper with
    | None -> prog_args
    | Some command -> ["/bin/sh"; "-c"; command ^ " \"$@\""; "-"] @ prog_args

  in config.system#exec prog_args ~env:env

(** This is called in a new process by the launcher created by [ensure_runenv]. *)
let runenv args =
  match args with
  | [] -> failwith "No args passed to runenv!"
  | arg0::args ->
    try
      let system = new Support.System.real_system in
      let var = "zeroinstall-runenv-" ^ Filename.basename arg0 in
      let s = Support.Utils.getenv_ex system var in
      let open Yojson.Basic in
      let envargs = Util.convert_each Util.to_string (from_string s) in
      system#exec (envargs @ args)
    with Safe_exception _ as ex -> reraise_with_context ex "... launching %s" arg0
;;
