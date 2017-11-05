(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
module U = Support.Utils

let write fd msg =
  Lwt_unix.write_string fd msg 0 (String.length msg) >>= fun wrote ->
  assert (wrote = String.length msg);
  Lwt.return ()

let handle_connection client =
  log_info "connection to fake gpg-agent";
  let from_client = Lwt_io.of_fd ~mode:Lwt_io.input client in
  write client "OK Pleased to meet you\n" >>= fun () ->
  let rec aux () =
    Lwt_io.read_line from_client >>= fun got ->
    log_info "[fake-gpg-agent]: got '%s'" got;
    let resp =
      if U.starts_with got "HAVEKEY" then
        "ERR 67108881 No secret key <GPG Agent>\n"
      else if U.starts_with got "AGENT_ID" then
        "ERR 67109139 Unknown IPC command <GPG Agent>\n"
      else "OK\n" in
    write client resp >>= fun () ->
    aux () in
  Lwt.catch aux
    (function
      | End_of_file -> Lwt_io.close from_client
      | ex -> Lwt.fail ex
    )

let run gpg_dir =
  let socket = Lwt_unix.(socket PF_UNIX SOCK_STREAM 0) in
  Unix.bind (Lwt_unix.unix_file_descr socket) (Lwt_unix.ADDR_UNIX (gpg_dir +/ "S.gpg-agent"));
  Lwt_unix.set_close_on_exec socket;
  Lwt_unix.listen socket 5;
  let rec aux () =
    Lwt_unix.accept socket >>= fun (client, _addr) ->
    Lwt.async (fun () -> handle_connection client);
    aux () in
  let thread = aux () in
  let task, _waker = Lwt.task () in
  Lwt.on_cancel task (fun () ->
    log_info "stopping gpg agent";
    Lwt.cancel thread;
    Lwt.async (fun () -> Lwt_unix.close socket);
  );
  task

let with_gpg test =
  Fake_system.with_tmpdir (fun tmpdir ->
    OUnit.skip_if on_windows "No PF_UNIX on Windows";
    let agent = run tmpdir in
    Lwt_main.run (
      Lwt.finalize
        (fun () -> test tmpdir)
        (fun () -> Lwt.cancel agent; Lwt.return ())
    )
  )
