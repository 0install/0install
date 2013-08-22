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
        config.system#atomic_write [Open_wronly; Open_binary] write path 0o755
      )

    method setenv name command_argv env =
      let open Yojson.Basic in
      let json :json = `List (List.map (fun a -> `String a) command_argv) in
      Env.putenv ("zeroinstall-runenv-" ^ name) (to_string json) env
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

class windows_launcher_builder config =
  let runenv_path =
    match config.system#getenv "ZEROINSTALL_RUNENV" with
    | None -> Filename.dirname config.abspath_0install +/ "0install-runenv.exe"
    | Some path -> path in
  let digest = config.system#with_open_in [Open_rdonly; Open_binary] 0 runenv_path Digest.input in
  object (_ : #launcher_builder)
    inherit launcher_builder config digest

    method! add_launcher path =
      if not @@ Sys.file_exists path then
        config.system#atomic_hardlink ~link_to:runenv_path ~replace:path
  end

let get_launcher_builder config =
  if on_windows then new windows_launcher_builder config
  else
    let buf = String.create 2 in
    let () = config.system#with_open_in [Open_rdonly; Open_binary] 0 config.abspath_0install (fun ch ->
      really_input ch buf 0 2
    )
    in
    if buf = "!#" then
      new bytecode_launcher_builder config
    else
      new native_launcher_builder config

let do_exec_binding dry_run builder env impls (iface_uri, {Binding.exec_type; Binding.name; Binding.command}) =
  validate_exec_name name;

  let exec_dir = builder#make_dir name in
  let exec_path = exec_dir +/ name in
  if not dry_run then (
    builder#add_launcher exec_path;
    Unix.chmod exec_dir 0o500;
  ) else (
    Dry_run.log "would create launcher %s" exec_path
  );

  let command_argv = Command.build_command ~dry_run impls iface_uri command env in

  let () = match exec_type with
  | Binding.InPath -> Binding.prepend "PATH" exec_dir path_sep env
  | Binding.InVar -> Env.putenv name exec_path env in

  builder#setenv name command_argv env

(* Make a map from InterfaceURIs to the selected <selection> and (for non-native packages) paths *)
let make_selection_map system stores sels =
  let add_selection m sel =
    let iface = ZI.get_attribute "interface" sel in
    let path =
      try Selections.get_path system stores sel
      with Stores.Not_stored msg ->
        raise_safe "Missing implementation for '%s' %s: %s" iface (ZI.get_attribute "version" sel) msg
    in
    let value = (sel, path) in
    StringMap.add iface value m
  in ZI.fold_left ~f:add_selection StringMap.empty sels "selection"
;;

(** Calculate the arguments and environment to pass to exec to run this
    process. This also ensures any necessary launchers exist, creating them
    if not. *)
let get_exec_args config ?main sels args =
  let env = Env.copy_current_env () in
  let impls = make_selection_map config.system config.stores sels in
  let bindings = Binding.collect_bindings impls sels in
  let launcher_builder = get_launcher_builder config in

  (* Do <environment> bindings; collect executable bindings *)
  let exec_bindings =
    Support.Utils.filter_map bindings ~f:(fun (iface, binding) -> match binding with
      | Binding.EnvironmentBinding b -> Binding.do_env_binding env impls iface b; None
      | Binding.ExecutableBinding b -> Some (iface, b)
      | Binding.GenericBinding elem -> Support.Qdom.log_elem Support.Logging.Warning "Unsupported binding type:" elem; None
    ) in

  (* Do <executable-in-*> bindings *)
  List.iter (do_exec_binding config.dry_run launcher_builder env impls) exec_bindings;

  let command = ZI.get_attribute "command" sels in
  let prog_args = (Command.build_command ?main ~dry_run:config.dry_run impls (ZI.get_attribute "interface" sels) command env) @ args in

  (prog_args, (Env.to_array env))

(** Run the given selections. If [wrapper] is given, run that command with the command we would have run as the arguments.
    If [finally] is given, run it just before execing. *)
let execute_selections config ?finally ?wrapper ?main sels args =
  let (prog_args, env) = get_exec_args config ?main sels args in

  let prog_args =
    match wrapper with
    | None -> prog_args
    | Some command -> ["/bin/sh"; "-c"; command ^ " \"$@\""; "-"] @ prog_args in

  let () =
    match finally with
    | None -> ()
    | Some cleanup -> cleanup () in

  if config.dry_run then
    Dry_run.log "would execute: %s" (String.concat " " prog_args)
  else
    config.system#exec prog_args ~env:env

(** This is called in a new process by the launcher created by [ensure_runenv]. *)
let runenv (system:system) args =
  match args with
  | [] -> failwith "No args passed to runenv!"
  | arg0::args ->
    try
      let var = "zeroinstall-runenv-" ^ Filename.basename arg0 in
      let s = Support.Utils.getenv_ex system var in
      let open Yojson.Basic in
      let envargs = Util.convert_each Util.to_string (from_string s) in
      system#exec (envargs @ args)
    with Safe_exception _ as ex -> reraise_with_context ex "... launching %s" arg0
;;
