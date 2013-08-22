(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Access to the rest of the system. This capabilities are provided via an object, which can be replaced for unit-testing.  *)

open Common

module type UnixType = module type of Unix

let wrap_unix_errors fn =
  try fn ()
  with Unix.Unix_error (errno, s1, s2) ->
    raise_safe "%s(%s): %s" s1 s2 (Unix.error_message errno)

let reap_child child_pid =
  match snd (Unix.waitpid [] child_pid) with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED code -> raise_safe "Child returned error exit status %d" code
    | Unix.WSIGNALED signal -> raise_safe "Child aborted (signal %d)" signal
    | Unix.WSTOPPED signal -> raise_safe "Child is currently stopped (signal %d)" signal

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
let canonical_machines = List.fold_left (fun map (k, v) -> StringMap.add k v map) StringMap.empty [
  ("all", "*");
  ("any", "*");
  ("noarch", "*");
  ("(none)", "*");
  ("amd64", "x86_64");
  ("x86", "i386");
  ("i86pc", "i686");
  ("Power Macintosh", "ppc");
]

(** Return the canonical name for this CPU, or None if we don't know one. *)
let canonical_machine s =
  try StringMap.find (String.lowercase s) canonical_machines
  with Not_found -> s

let canonical_os = function
  | "SunOS" -> "Solaris"
  | x when Utils.starts_with x "CYGWIN_NT" -> "Cygwin"
  | x -> x

module RealSystem (U : UnixType) =
  struct
    class real_system =
      let platform = ref None in

      object (self : #system)
        method argv () = Sys.argv
        method print_string = print_string
        method time = Unix.time
        method mkdir = Unix.mkdir
        method file_exists = Sys.file_exists
        method create_process args new_stdin new_stdout new_stderr =
          log_info "Running %s" @@ Logging.format_argv_for_logging args;
          try
            wrap_unix_errors (fun () ->
              Unix.create_process (List.hd args) (Array.of_list args) new_stdin new_stdout new_stderr
            )
          with Safe_exception _ as ex ->
            reraise_with_context ex "... trying to create sub-process '%s'"
              (Logging.format_argv_for_logging args)

        method unlink = Unix.unlink
        method rmdir = Unix.rmdir
        method getcwd = Sys.getcwd
        method chmod = Unix.chmod
        method set_mtime path mtime =
          if mtime = 0.0 then (* FIXME *)
            failwith "OCaml cannot set mtime to 0, sorry" (* Would interpret it as the current time *)
          else
            Unix.utimes path mtime mtime

        method readlink path =
          try Some (Unix.readlink path)
          with Unix.Unix_error _ -> None

        method readdir path =
          try Success (Sys.readdir path)
          with Sys_error _ as ex -> Problem ex

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
        method with_open_in open_flags mode file fn =
          let (ch:in_channel) =
            try open_in_gen open_flags mode file
            with Sys_error msg -> raise_safe "Open failed: %s" msg in
          Utils.finally close_in ch fn

        (** [with_open_out fn file] opens [file] for writing, calls [fn handle], and then closes it again. *)
        method with_open_out open_flags mode file fn =
          let (ch:out_channel) =
            try open_out_gen open_flags mode file
            with Sys_error msg -> raise_safe "Open failed: %s" msg in
          Utils.finally close_out ch fn

        (** A safer, more friendly version of the [Unix.exec*] calls.
            Flushes [stdout] and [stderr]. Ensures [argv[0]] is set to the program called.
            Reports errors as [Safe_exception]s.
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
              if !Logging.threshold >= Logging.Info then
                log_info "exec %s" @@ Logging.format_argv_for_logging argv;
              if on_windows then (
                let open Unix in
                let run_child _args =
                  let child_pid =
                    match env with
                    | None -> Unix.create_process prog_path argv_array stdin stdout stderr
                    | Some env -> Unix.create_process_env prog_path argv_array env stdin stdout stderr in
                  match snd (waitpid [] child_pid) with
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
          with Safe_exception _ as ex ->
            let cmd = String.concat " " argv in
            reraise_with_context ex "... trying to exec: %s" cmd

        method spawn_detach ?(search_path = false) ?env argv =
          try
            wrap_unix_errors (fun () ->
              let argv_array = Array.of_list argv in
              let prog_path =
                if search_path then Utils.find_in_path_ex (self :> system) (List.hd argv)
                else (List.hd argv) in

              if !Logging.threshold <= Logging.Info then
                log_info "spawn %s" @@ Logging.format_argv_for_logging argv;

              flush stdout;
              flush stderr;

              let do_spawn () =
                (* We don't reap the child. On Unix, we're in a child process that is about to exit anyway (init will inherit the child).
                   On Windows, hopefully it doesn't matter. *)
                ignore @@ Utils.finally Unix.close (Unix.openfile dev_null [Unix.O_WRONLY] 0) (fun null_fd ->
                  let stderr = if !Logging.threshold = Logging.Debug then Unix.stderr else null_fd in
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
          with Safe_exception _ as ex ->
            let cmd = String.concat " " argv in
            reraise_with_context ex "... trying to spawn: %s" cmd

        (** Create and open a new text file, call [fn chan] on it, and rename it over [path] on success. *)
        method atomic_write open_flags fn path mode =
          let dir = Filename.dirname path in
          let (tmpname, ch) =
            try Filename.open_temp_file ~mode:open_flags ~temp_dir:dir "tmp-" ".new"
            with Sys_error msg -> raise_safe "open_temp_file failed: %s" msg
          in
          let result = Utils.finally close_out ch fn in
          try
            wrap_unix_errors (fun () ->
              Unix.chmod tmpname mode;
              Unix.rename tmpname path
            );
            result
          with Safe_exception _ as ex -> reraise_with_context ex "... trying to write '%s'" path

        method atomic_hardlink ~link_to ~replace =
          if on_windows then (
            if Sys.file_exists replace then
              Unix.unlink replace;
            Unix.link link_to replace
          ) else (
            let tmp = (replace ^ ".new") in
            if Sys.file_exists tmp then
              Unix.unlink tmp;
            Unix.link link_to tmp;
            Unix.rename tmp replace
          )

        method getenv name =
          try Some (Sys.getenv name)
          with Not_found -> None

        (** Call [waitpid] to collect the child.
            @raise Safe_exception if it didn't exit with a status of 0 (success). *)
        method reap_child ?(kill_first) child_pid =
          let () = match kill_first with
            | None -> ()
            | Some signal -> Unix.kill child_pid signal in
          reap_child child_pid

        method platform () =
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
                  let uname = trim @@ Utils.check_output system input_line [Utils.find_in_path_ex system "uname"; "-srm"] in
                  match Str.bounded_split_delim Utils.re_space uname 3 with
                  | ["Darwin"; release; machine] ->
                      let os =
                        if Sys.file_exists "/System/Library/Frameworks/Carbon.framework" then "MacOSX" else "Darwin" in
                      let machine =
                        if machine = "i386" then (
                          let cpu64 = trim @@ Utils.check_output system input_line
                            [Utils.find_in_path_ex system "sysctl"; "-n"; "hw.cpu64bit_capable"] in
                          if cpu64 = "1" then "x86_64" else "i386"
                        ) else machine in
                      {os; release; machine}
                    | [os; release; machine] -> {
                        os = canonical_os os;
                        release;
                        machine = canonical_machine machine;
                      }
                  | _ ->
                      log_warning "Failed to parse uname details from '%s'!" uname;
                      {os = "unknown"; release = "1"; machine = "i686"}
                ) in

              platform := Some p;
              p
      end
  end
