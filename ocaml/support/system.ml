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
    method lstat = Unix.lstat
    method create_process = Unix.create_process
    method getcwd = Sys.getcwd

    (** [with_open fn file] opens [file], calls [fn handle], and then closes it again. *)
    method with_open fn file =
      let ch =
        try open_in file
        with Sys_error msg -> raise_safe msg
      in
      let result = try fn ch with ex -> close_in ch; raise ex in
      let () = close_in ch in
      result

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
          Utils.handle_exceptions run_child
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
    method atomic_write fn path mode =
      let dir = Filename.dirname path in
      let (tmpname, ch) =
        try Filename.open_temp_file ~temp_dir:dir "tmp-" ".new"
        with Sys_error msg -> raise_safe msg
      in
      let result = try fn ch with ex -> close_out ch; raise ex in
      let () = close_out ch in
      Unix.chmod tmpname mode;
      Unix.rename tmpname path;
      result

    method getenv name =
      try Some (Sys.getenv name)
      with Not_found -> None

  end
;;
