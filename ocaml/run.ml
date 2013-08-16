(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install run" command *)

open Zeroinstall.General
open Support.Common
open Options

type run_options = {
  mutable wrapper : string option;
}

let handle options args =
  match args with
  | arg :: run_args -> (
    let sels = Generic_select.handle options arg Generic_select.Select_for_run in

    let run_opts = {
      wrapper = None;
    } in
    Support.Argparse.iter_options options.extra_options (function
      | Wrapper w -> run_opts.wrapper <- Some w
      | ShowManifest -> raise_safe "The -m argument is ambiguous before the 'run' argument. Put it after, or use --main"
      | _ -> raise Fallback_to_Python   (* TODO: -m etc *)
    );

    try Zeroinstall.Exec.execute_selections options.config sels run_args ?wrapper:run_opts.wrapper
    with Safe_exception _ as ex -> reraise_with_context ex "... running %s" arg
  )
  | _ -> raise Support.Argparse.Usage_error
