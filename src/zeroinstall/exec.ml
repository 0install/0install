(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open General
open Support
open Support.Common

let re_exec_name = Str.regexp "^[^./'][^/']*$"

let validate_exec_name name =
  if Str.string_match re_exec_name name 0 then
    ()
  else
    Safe_exn.failf "Invalid name in executable binding: %s" name

class launcher_builder config script =
  let hash = String.sub (Digest.to_hex @@ Digest.string script) 0 6 in
  object
    method save_path name =
      Paths.Cache.(save_path (named_runner ~hash name)) config.paths

    method add_launcher path =
      if not @@ Sys.file_exists path then (
        path |> config.system#atomic_write [Open_wronly; Open_binary] ~mode:0o755 (fun ch ->
          output_string ch script
        )
      )

    method setenv name command_argv env =
      let open Yojson.Basic in
      let json : Yojson.Basic.t = `List (List.map (fun a -> `String a) command_argv) in
      let envname = "zeroinstall_runenv_" ^ name in
      let value = to_string json in
      log_info "%s=%s" envname value;
      env := Env.put envname value !env
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
  let digest = config.system#with_open_in [Open_rdonly; Open_binary] Digest.input runenv_path in
  object (_ : #launcher_builder)
    inherit launcher_builder config digest

    method! add_launcher path =
      if not @@ Sys.file_exists path then
        Support.Utils.atomic_hardlink config.system ~link_to:runenv_path ~replace:path
  end

let get_launcher_builder config =
  if on_windows then new windows_launcher_builder config
  else
    let buf = config.abspath_0install |> config.system#with_open_in [Open_rdonly; Open_binary] (Support.Utils.read_upto 2) in
    if buf = "#!" then
      new bytecode_launcher_builder config
    else (
      (* If abspath_0install is a native binary, we can avoid starting a shell here. *)
      let script = Printf.sprintf "#!%s runenv\n" config.abspath_0install in
      if String.length script < 128 then
        new launcher_builder config script (* execve(2) says 127 is the maximum *)
      else
        new bytecode_launcher_builder config
    )

let do_exec_binding dry_run builder env impls (role, {Binding.exec_type; Binding.name; Binding.command}) =
  validate_exec_name name;

  let exec_path = builder#save_path (name +/ name) in
  let exec_dir = Filename.dirname exec_path in
  if not dry_run then (
    builder#add_launcher exec_path;
    try
      Unix.chmod exec_dir 0o500;
    with ex ->
      log_warning ~ex "chmod %S failed" exec_dir
  ) else (
    Dry_run.log "would create launcher %s" exec_path
  );

  let req = {Selections.command = Some command; role} in
  let command_argv = Command.build_command ~dry_run impls req !env in

  let () = match exec_type with
  | Binding.InPath -> Binding.prepend "PATH" exec_dir path_sep env
  | Binding.InVar ->
      log_info "%s=%s" name exec_path;
      env := Env.put name exec_path !env in

  builder#setenv name command_argv env

(* Make a map from InterfaceURIs to the selected <selection> and (for non-native packages) paths *)
let make_selection_map system stores sels =
  Selections.to_map sels |> Selections.RoleMap.mapi (fun role sel ->
    let path =
      try Selections.get_path system stores sel
      with Stores.Not_stored msg ->
        Safe_exn.failf "Missing implementation for '%a' %s: %s" Selections.Role.pp role (Element.version sel) msg
    in
    (sel, path)
  )

let get_exec_args config ?main sels args =
  let env = ref @@ Env.of_array config.system#environment in
  let impls = make_selection_map config.system config.stores sels in
  let bindings = Selections.collect_bindings sels in
  let launcher_builder = get_launcher_builder config in

  (* Do <environment> bindings; collect executable bindings *)
  let exec_bindings =
    bindings |> List.filter_map (fun (role, binding) -> match Binding.parse_binding binding with
      | Binding.EnvironmentBinding b ->
          let sel = lazy (
            Selections.RoleMap.find_opt role impls
            |? lazy (Safe_exn.failf "Missing role '%a' in selections!" Selections.Role.pp role)
          ) in
          Binding.do_env_binding env sel b; None
      | Binding.ExecutableBinding b -> Some (role, b)
      | Binding.GenericBinding elem -> Element.log_elem Support.Logging.Warning "Unsupported binding type:" elem; None
    ) in

  (* Do <executable-in-*> bindings *)
  List.iter (do_exec_binding config.dry_run launcher_builder env impls) exec_bindings;
  let env = !env in

  let prog_args = (Command.build_command ?main ~dry_run:config.dry_run impls (Selections.requirements sels) env) @ args in

  (prog_args, (Env.to_array env))

let execute_selections config ?exec ?wrapper ?main sels args =
  if main = None && Selections.root_command sels = None then
    Safe_exn.failf "Can't run: no command specified!";

  let (prog_args, env) = get_exec_args config ?main sels args in

  let prog_args =
    match wrapper with
    | None -> prog_args
    | Some command -> ["/bin/sh"; "-c"; command ^ " \"$@\""; "-"] @ prog_args in

  if config.dry_run then
    `Dry_run (Printf.sprintf "would execute: %s" (String.concat " " prog_args))
  else match exec with
  | None -> `Ok (config.system#exec prog_args ~env:env)
  | Some exec -> `Ok (exec prog_args ~env:env)
