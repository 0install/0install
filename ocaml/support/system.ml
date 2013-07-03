(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Access to the rest of the system. This capabilities are provided via an object, which can be replaced for unit-testing.  *)

open Common

class real_system =
  object (self : #system)
    method time = Unix.time
    method mkdir = Unix.mkdir
    method file_exists = Sys.file_exists
    method create_process = Unix.create_process
    method unlink = Unix.unlink
    method rmdir = Unix.rmdir
    method getcwd = Sys.getcwd
    method chmod = Unix.chmod

    method readdir path =
      try Success (Sys.readdir path)
      with Sys_error _ as ex -> Failure ex

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
        let argv_array = Array.of_list argv in
        let prog_path =
          if search_path then Utils.find_in_path_ex (self :> system) (List.hd argv)
          else (List.hd argv) in
        log_info "exec %s" @@ String.concat " " argv;
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
      with Unix.Unix_error _ as ex ->
        let cmd = String.concat " " argv in
        raise (Safe_exception (Printexc.to_string ex, ref ["... trying to exec: " ^ cmd]))

    (** Create and open a new text file, call [fn chan] on it, and rename it over [path] on success. *)
    method atomic_write open_flags fn path mode =
      let dir = Filename.dirname path in
      let (tmpname, ch) =
        try Filename.open_temp_file ~mode:open_flags ~temp_dir:dir "tmp-" ".new"
        with Sys_error msg -> raise_safe "open_temp_file failed: %s" msg
      in
      let result = Utils.finally close_out ch fn in
      Unix.chmod tmpname mode;
      Unix.rename tmpname path;
      result

    method getenv name =
      try Some (Sys.getenv name)
      with Not_found -> None

    (** Call [waitpid] to collect the child.
        @raise Safe_exception if it didn't exit with a status of 0 (success). *)
    method reap_child ?(kill_first) child_pid =
      let () = match kill_first with
        | None -> ()
        | Some signal -> Unix.kill child_pid signal in
      match snd (Unix.waitpid [] child_pid) with
        | Unix.WEXITED 0 -> ()
        | Unix.WEXITED code -> raise_safe "Child returned error exit status %d" code
        | Unix.WSIGNALED signal -> raise_safe "Child aborted (signal %d)" signal
        | Unix.WSTOPPED signal -> raise_safe "Child is currently stopped (signal %d)" signal


  end
;;
