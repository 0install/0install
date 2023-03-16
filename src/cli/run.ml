(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install run" command *)

open Support
open Options
open Zeroinstall.General

module U = Support.Utils

type run_options = {
  mutable wrapper : string option;
  mutable main : string option;
}

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
    | `ShowManifest -> Safe_exn.failf "The -m argument is ambiguous before the 'run' argument. Put it after, or use --main"
    | `MainExecutable m -> run_opts.main <- Some m
  );

  match args with
  | arg :: run_args -> (
    let sels = Generic_select.handle options !select_opts arg `Select_for_run in

    let exec args ~env =
      options.config.system#exec args ~env in

    try
      match Zeroinstall.Exec.execute_selections ~exec options.config sels run_args ?main:run_opts.main ?wrapper:run_opts.wrapper with
      | `Dry_run msg -> Zeroinstall.Dry_run.log "%s" msg
      | `Ok () -> ()
    with Safe_exn.T _ as ex -> Safe_exn.reraise_with ex "... running %s" arg
  )
  | _ -> raise (Support.Argparse.Usage_error 1)
