(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main executable *)

open Support;;

let () =
  try
    let config = Config.get_default_config () in
    match List.tl (Array.to_list Sys.argv) with
    | [] -> raise_safe "usage: runsels selections.xml arg..."
    | (app_or_sels :: args) ->
        let sels_path = match Apps.lookup_app app_or_sels config with
        | None -> app_or_sels
        | Some app_path -> app_path +/ "selections.xml" in
        let sels = Selections.load_selections sels_path in
        try Run.execute_selections sels args config
        with Safe_exception _ as ex -> reraise_with_context ex ("... running selections " ^ sels_path)
  with
  | Safe_exception (msg, context) ->
      Printf.eprintf "%s\n" msg;
      List.iter (Printf.eprintf "%s\n") (List.rev !context);
      Printexc.print_backtrace stderr;
      exit 1
  | ex ->
      output_string stderr (Printexc.to_string ex);
      output_string stderr "\n";
      if not (Printexc.backtrace_status ()) then
        output_string stderr "(hint: run with OCAMLRUNPARAM=b to get a stack-trace)\n"
      else
        Printexc.print_backtrace stderr;
      exit 1
;;
