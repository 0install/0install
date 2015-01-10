(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install run" command *)

open Support.Common
open Options
open Zeroinstall.General

module U = Support.Utils

type run_options = {
  mutable wrapper : string option;
  mutable main : string option;
}

(** This is run when the user clicks the test button in the bug-report dialog box. *)
let run_test options run_opts run_args sels =
  let result, set_result = Lwt.wait () in

  let exec args ~env =
    U.async (fun () ->
      try_lwt
        let command = (U.find_in_path_ex options.config.system (List.hd args), Array.of_list args) in
        lwt out = Lwt_process.pread ~env ~stderr:(`FD_copy Unix.stdout) command in
        Lwt.wakeup set_result out;
        Lwt.return ()
      with ex ->
        Lwt.wakeup_exn set_result ex;
        Lwt.return ()
    ) in

  let () =
    try
      Zeroinstall.Exec.execute_selections ~exec options.config sels run_args ?main:run_opts.main ?wrapper:run_opts.wrapper;
    with ex ->
      log_info ~ex "Error from test command";
      Lwt.wakeup_exn set_result ex in

  result

let handle options flags args =
  let run_opts = {
    wrapper = None;
    main = None;
  } in
  let select_opts = ref [] in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
    | #binary_select_option | `Refresh as o -> select_opts := o :: !select_opts
    | `Wrapper w -> run_opts.wrapper <- Some w
    | `ShowManifest -> raise_safe "The -m argument is ambiguous before the 'run' argument. Put it after, or use --main"
    | `MainExecutable m -> run_opts.main <- Some m
  );

  match args with
  | arg :: run_args -> (
    let sels = Generic_select.handle options ~test_callback:(run_test options run_opts run_args) !select_opts arg `Select_for_run in

    let exec args ~env =
      options.config.system#exec args ~env in

    try Zeroinstall.Exec.execute_selections ~exec options.config sels run_args ?main:run_opts.main ?wrapper:run_opts.wrapper
    with Safe_exception _ as ex -> reraise_with_context ex "... running %s" arg
  )
  | _ -> raise (Support.Argparse.Usage_error 1)
