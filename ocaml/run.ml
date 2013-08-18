(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install run" command *)

open Support.Common
open Options

type run_options = {
  mutable wrapper : string option;
  mutable main : string option;
}

let handle options args =
  match args with
  | arg :: run_args -> (
    let sels = Generic_select.handle options arg Zeroinstall.Helpers.Select_for_run in

    let run_opts = {
      wrapper = None;
      main = None;
    } in
    Support.Argparse.iter_options options.extra_options (function
      | Wrapper w -> run_opts.wrapper <- Some w
      | ShowManifest -> raise_safe "The -m argument is ambiguous before the 'run' argument. Put it after, or use --main"
      | MainExecutable m -> run_opts.main <- Some m
      | _ -> raise_safe "Unknown option"
    );

    try Zeroinstall.Exec.execute_selections options.config sels run_args ?main:run_opts.main ?wrapper:run_opts.wrapper
    with Safe_exception _ as ex -> reraise_with_context ex "... running %s" arg
  )
  | _ -> raise Support.Argparse.Usage_error
