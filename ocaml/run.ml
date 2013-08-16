(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install run" command *)

open Zeroinstall.General
open Support.Common
open Options

type run_options = {
  mutable must_select : bool;
  mutable refresh : bool;
  mutable wrapper : string option;
}

let handle options args =
  let parse_opts remaining_options =
    let run_opts = {
      must_select = (remaining_options <> options.extra_options) || options.gui = Yes;
      refresh = false;
      wrapper = None;
    } in
    Support.Argparse.iter_options remaining_options (function
      | Refresh -> run_opts.refresh <- true; run_opts.must_select <- true;
      | Wrapper w -> run_opts.wrapper <- Some w
      | ShowManifest -> raise_safe "The -m argument is ambiguous before the 'run' argument. Put it after, or use --main"
      | _ -> raise Fallback_to_Python   (* TODO: -m etc *)
    );
    run_opts in

  match args with
  | arg :: run_args -> (
    let execute opts sels =
      try Zeroinstall.Exec.execute_selections options.config sels run_args ?wrapper:opts.wrapper
      with Safe_exception _ as ex -> reraise_with_context ex "... running %s" arg in

    let do_selections opts reqs =
      (* Run the solver to get the selections, then run them. *)
      let sels = Select.get_selections options ~refresh:opts.refresh reqs Select.Select_for_run in
      match sels with
      | None -> exit 1    (* Aborted by user *)
      | Some sels -> execute opts sels
    in

    match Select.resolve_target options.config arg with
    | Select.App path ->
        let open Zeroinstall.Apps in
        let old_reqs = get_requirements options.config.system path in
        let (new_options, reqs) = Req_options.parse_update_options options.extra_options old_reqs in
        let opts = parse_opts new_options in

        if opts.must_select then (
          log_info "Getting new selections for %s" path;
          do_selections opts reqs           (* Select a new set of version based on this app's requirements *)
        ) else (
          (* note: pass use_gui here once we support foreground updates for apps in OCaml *)
          let sels = get_selections_may_update options.config (Lazy.force options.distro) path in
          execute opts sels                 (* No selection options given - execute the current selections *)
        )
    | Select.Interface iface_uri ->
        let (new_options, reqs) = Req_options.parse_options options.extra_options iface_uri ~command:(Some "run") in
        let opts = parse_opts new_options in
        do_selections opts reqs
    | Select.Selections root ->
        let iface_uri = ZI.get_attribute "interface" root in
        let command = ZI.get_attribute_opt "command" root in
        let (new_options, reqs) = Req_options.parse_options options.extra_options iface_uri ~command in
        let opts = parse_opts new_options in

        if opts.must_select then (
          log_info "Getting new selections for %s" (List.hd args);
          do_selections opts reqs           (* Select a new set of version based on this file *)
        ) else (
          execute opts root                 (* No selection options given - execute the selections in the file *)
        )
  )
  | _ -> raise Support.Argparse.Usage_error
