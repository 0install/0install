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

let autocompile options sels reason =
  (** if sels has any source impls, passes the entire selections document through `0compile autocompile`,
   * which will compile all source impls. After that's done, we reselect and run the result *)

  (*TODO: allow override with $ZI_0COMPILE_FEED or something? *)
  log_debug "Getting 0compile selections...";
  let compile_sels = Generic_select.handle options [`Autocompile false; `NotBefore "1.3-post"] "http://0install.net/2006/interfaces/0compile.xml" `Select_for_run in

  let exec args ~env =
    let tmp_filename, tmp_file = Filename.open_temp_file "0compile-sels-" ".xml" in
    U.finally_do Unix.unlink tmp_filename (fun tmp_filename ->
      U.finally_do close_out tmp_file (fun tmp_file ->
        let xml_selections = Zeroinstall.Selections.as_xml sels in
        Support.Qdom.output (Xmlm.make_output @@ `Channel tmp_file) xml_selections;
      );
      log_debug "Executing: %s" (String.concat " " args);
      let child = options.config.system#create_process ~env (args@[tmp_filename]) Unix.stdin Unix.stdout Unix.stderr in
      options.config.system#reap_child child
    ) in

  begin
    try Zeroinstall.Exec.execute_selections ~exec options.config compile_sels ["autocompile"; "--selections"]
    with Safe_exception _ as ex -> reraise_with_context ex "... compiling sources for %s" reason
  end;
  ()

let handle options flags args =
  let run_opts = {
    wrapper = None;
    main = None;
  } in
  let select_opts = ref [] in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
    | #select_option | `Refresh as o -> select_opts := o :: !select_opts
    | `Wrapper w -> run_opts.wrapper <- Some w
    | `ShowManifest -> raise_safe "The -m argument is ambiguous before the 'run' argument. Put it after, or use --main"
    | `MainExecutable m -> run_opts.main <- Some m
  );

  match args with
  | arg :: run_args -> (
    let do_select extra_opts =
      Generic_select.handle options
        ~test_callback:(run_test options run_opts run_args) (!select_opts@extra_opts) arg `Select_for_run in
    let sels = do_select [] in

    let sels = if Zeroinstall.Selections.requires_compilation sels
      then begin
        autocompile options sels arg;
        (* TODO: pin exact implementation IDs here, for efficiency? *)
        do_select [`Autocompile false]
      end else sels in

    let exec args ~env =
      options.config.system#exec args ~env in

    try Zeroinstall.Exec.execute_selections ~exec options.config sels run_args ?main:run_opts.main ?wrapper:run_opts.wrapper
    with Safe_exception _ as ex -> reraise_with_context ex "... running %s" arg
  )
  | _ -> raise (Support.Argparse.Usage_error 1)
