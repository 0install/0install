(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Common

module type UnixType = module type of Unix

let set_mtime path t =
  (* Note: can't use 0.0 for the atime, as that will fail if [t = 0.0]. *)
  Unix.utimes path (Unix.gettimeofday ()) t

external uname : unit -> Platform.t = "ocaml_0install_uname"

let wrap_unix_errors fn =
  try fn ()
  with Unix.Unix_error (errno, s1, s2) ->
    Safe_exn.failf "%s(%s): %s" s1 s2 (Unix.error_message errno)

let check_exit_status = function
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code -> Safe_exn.failf "Child returned error exit status %d" code
  | Unix.WSIGNALED signal -> Safe_exn.failf "Child aborted (signal %d)" signal
  | Unix.WSTOPPED signal -> Safe_exn.failf "Child is currently stopped (signal %d)" signal

(* From Unix.ml (not exported) *)
let rec waitpid_non_intr pid =
  try Unix.waitpid [] pid
  with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_non_intr pid

let reap_child child_pid =
  check_exit_status @@ snd @@ waitpid_non_intr child_pid

(** Run [fn ()] in a child process. [fn] will spawn a grandchild process and return without waiting for it.
    The child process then exits, allowing the original parent to reap it and continue, while the grandchild
    continues running, detached. *)
let double_fork_detach fn =
  match Unix.fork() with
  | 0 -> (
      (* We are the child *)
      try fn (); exit 0
      with _ -> exit 1
  )
  | child_pid -> reap_child child_pid

let dev_null =
  if on_windows then "NUL"
  else "/dev/null"

(* Maps machine type names used in packages to their Zero Install versions
   (updates to this might require changing the reverse Java mapping) *)
let canonical_machines = List.fold_left (fun map (k, v) -> XString.Map.add k v map) XString.Map.empty [
  ("all", "*");
  ("any", "*");
  ("noarch", "*");
  ("(none)", "*");
  ("amd64", "x86_64");
  ("x86", "i386");
  ("i86pc", "i686");
  ("Power Macintosh", "ppc");
  ("armhf", "armv6l");  (* Not sure what version it should be, but unlikely apt-cache will report an incompatible arch anyway *)
  ("armv6h", "armv6l"); (* Arch Linux ARM for Raspberry Pi calls it armv6h, assumedly indicating hard-float *)
  ("arm64", "aarch64")
]

(** Return the canonical name for this CPU, or [s] if we don't know one. *)
let canonical_machine s =
  XString.Map.find_opt (String.lowercase_ascii s) canonical_machines |? lazy s

let canonical_os = function
  | "SunOS" -> "Solaris"
  | x when XString.starts_with x "CYGWIN_NT" -> "Cygwin"
  | x -> x

module RealSystem (U : UnixType) =
  struct
    class real_system =
      let platform = ref None in

      object (self : #system)
        method argv = Sys.argv
        method isatty = Unix.isatty
        method time = Unix.time ()
        method mkdir = Unix.mkdir
        method file_exists = Sys.file_exists
        method create_process ?env args new_stdin new_stdout new_stderr =
          log_info "Running %s" @@ Logging.format_argv_for_logging args;
          try
            wrap_unix_errors (fun () ->
              match env with
              | None -> Unix.create_process (List.hd args) (Array.of_list args) new_stdin new_stdout new_stderr
              | Some env -> Unix.create_process_env (List.hd args) (Array.of_list args) env new_stdin new_stdout new_stderr
            )
          with Safe_exn.T _ as ex ->
            Safe_exn.reraise_with ex "... trying to create sub-process '%s'"
              (Logging.format_argv_for_logging args)

        method unlink = Unix.unlink
        method rmdir = Unix.rmdir
        method getcwd = Sys.getcwd ()
        method chdir = Unix.chdir
        method chmod = Unix.chmod
        method rename = Unix.rename
        method set_mtime = set_mtime

        method readlink path =
          try Some (Unix.readlink path)
          with Unix.Unix_error _ -> None

        method symlink ~target ~newlink =
          Unix.symlink target newlink

        method readdir path =
          try Ok (Sys.readdir path)
          with Sys_error _ as ex -> Error ex

        method lstat path =
          try Some (Unix.lstat path)
          with Unix.Unix_error (errno, _, _) as ex ->
            if errno = Unix.ENOENT then None
            else raise ex

        method stat path =
          try Some (Unix.stat path)
          with Unix.Unix_error (errno, _, _) as ex ->
            if errno = Unix.ENOENT then None
            else raise ex

        (** [with_open_in fn file] opens [file] for reading, calls [fn handle], and then closes it again. *)
        method with_open_in open_flags fn file =
          let (ch:in_channel) =
            try open_in_gen open_flags 0 file
            with Sys_error msg -> Safe_exn.failf "Open failed: %s" msg in
          Utils.finally_do close_in ch fn

        (** [with_open_out fn file] opens [file] for writing, calls [fn handle], and then closes it again. *)
        method with_open_out open_flags ~mode fn file =
          let (ch:out_channel) =
            try open_out_gen open_flags mode file
            with Sys_error msg -> Safe_exn.failf "Open failed: %s" msg in
          Utils.finally_do close_out ch fn

        (** A safer, more friendly version of the [Unix.exec*] calls.
            Flushes [stdout] and [stderr]. Ensures [argv[0]] is set to the program called.
            Reports errors as [Safe_exn.T]s.
            On Windows, we can't exec, so we spawn a subprocess, wait for it to finish, then
            exit with its exit status.
          *)
        method exec ?(search_path = false) ?env argv =
          flush stdout;
          flush stderr;
          try
            wrap_unix_errors (fun () ->
              let argv_array = Array.of_list argv in
              let prog_path =
                if search_path then Utils.find_in_path_ex (self :> system) (List.hd argv)
                else (List.hd argv) in
              if Logging.will_log Logging.Info then
                log_info "exec %s" @@ Logging.format_argv_for_logging argv;
              if on_windows then (
                let run_child _args =
                  let child_pid =
                    match env with
                    | None -> Unix.create_process prog_path argv_array Unix.stdin Unix.stdout Unix.stderr
                    | Some env -> Unix.create_process_env prog_path argv_array env Unix.stdin Unix.stdout Unix.stderr in
                  match snd (waitpid_non_intr child_pid) with
                  | Unix.WEXITED code -> exit code
                  | _ -> exit 127 in
                Utils.handle_exceptions run_child []
                (* doesn't return *)
              ) else (
                match env with
                | None -> Unix.execv prog_path argv_array
                | Some env -> Unix.execve prog_path argv_array env
              )
            )
          with Safe_exn.T _ as ex ->
            let cmd = String.concat " " argv in
            Safe_exn.reraise_with ex "... trying to exec: %s" cmd

        (* The child's stderr is /dev/null, unless debug logging is on. *)
        method spawn_detach ?(search_path = false) ?env argv =
          try
            wrap_unix_errors (fun () ->
              let argv_array = Array.of_list argv in
              let prog_path =
                if search_path then Utils.find_in_path_ex (self :> system) (List.hd argv)
                else (List.hd argv) in

              if Logging.will_log Logging.Info then
                log_info "spawn %s" @@ Logging.format_argv_for_logging argv;

              flush stdout;
              flush stderr;

              let do_spawn () =
                (* We don't reap the child. On Unix, we're in a child process that is about to exit anyway (init will inherit the child).
                   On Windows, hopefully it doesn't matter. *)
                ignore @@ Utils.finally_do Unix.close (Unix.openfile dev_null [Unix.O_WRONLY] 0) (fun null_fd ->
                  let stderr = if Logging.will_log Logging.Debug then Unix.stderr else null_fd in
                  match env with
                    | None -> Unix.create_process prog_path argv_array null_fd null_fd stderr
                    | Some env -> Unix.create_process_env prog_path argv_array env null_fd null_fd stderr
                ) in

              if on_windows then (
                do_spawn ()
              ) else (
                double_fork_detach do_spawn
              )
            )
          with Safe_exn.T _ as ex ->
            let cmd = String.concat " " argv in
            Safe_exn.reraise_with ex "... trying to spawn: %s" cmd

        (** Create and open a new text file, call [fn chan] on it, and rename it over [path] on success. *)
        method atomic_write open_flags ~mode fn path =
          let dir = Filename.dirname path in
          let (tmpname, ch) =
            try Filename.open_temp_file ~mode:open_flags ~temp_dir:dir "tmp-" ".new"
            with Sys_error msg -> Safe_exn.failf "open_temp_file failed: %s" msg
          in
          let result = Utils.finally_do close_out ch fn in
          try
            wrap_unix_errors (fun () ->
              Unix.chmod tmpname mode;
              Unix.rename tmpname path
            );
            result
          with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... trying to write '%s'" path

        method hardlink src dst = Unix.link src dst

        method getenv name = Sys.getenv_opt name

        method environment = Unix.environment ()

        method waitpid_non_intr = waitpid_non_intr

        (** Call [waitpid] to collect the child.
            @raise Safe_exn.T if it didn't exit with a status of 0 (success). *)
        method reap_child ?(kill_first) child_pid =
          let () = match kill_first with
            | None -> ()
            | Some signal -> Unix.kill child_pid signal in
          reap_child child_pid

        method platform =
          match !platform with
          | Some p -> p
          | None ->
              let open Platform in
              let system = (self :> system) in
              let p =
                if Sys.os_type = "Win32" then (
                  let machine =
                    try ignore @@ Sys.getenv "ProgramFiles(x86)"; "x86_64"
                    with Not_found -> "i686" in
                  {os = "Windows"; release = "Unknown"; machine}
                ) else (
                  let {os; release; machine} = uname () in
                  if os = "Darwin" then (
                    let os =
                      if Sys.file_exists "/System/Library/Frameworks/Carbon.framework" then "MacOSX" else "Darwin" in
                    let machine =
                      if machine = "i386" then (
                        let cpu64 = String.trim @@ Utils.check_output system input_line
                          [Utils.find_in_path_ex system "sysctl"; "-n"; "hw.cpu64bit_capable"] in
                        if cpu64 = "1" then "x86_64" else "i386"
                      ) else canonical_machine machine in
                    {os; release; machine}
                  ) else (
                    {os; release; machine = canonical_machine machine}
                  )
                ) in

              platform := Some p;
              p

        method running_as_root = Sys.os_type = "Unix" && Unix.geteuid () = 0

        method windows_api =
          if on_windows then (
            let wow64 = self#platform.Platform.machine = "x86_64" in
            Some (Windows_api.v ~wow64)
          ) else None

        method bypass_dryrun = (self :> system)
      end
  end
