(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main executable *)

open Support;;

let is_option x = String.length x > 0 && x.[0] = '-';;

let main () =
  let argv = (Array.to_list Sys.argv) in
  match argv with
  (* 0install run ... *)
  | (_ :: "run" :: app_or_sels :: args) when not (is_option app_or_sels) -> (
    let config = Config.get_default_config () in
    let sels_path = match Apps.lookup_app app_or_sels config with
    | None -> app_or_sels
    | Some app_path -> app_path +/ "selections.xml" in
    let sels = Selections.load_selections sels_path in
    try Run.execute_selections sels args config
    with Safe_exception _ as ex -> reraise_with_context ex ("... running selections " ^ sels_path)
  )
  (* For all other cases, fall back to the Python version *)
  | prog :: args ->
      (* Use ../0install if it exists *)
      let local_0install = Filename.dirname (Filename.dirname (abspath prog)) +/ "0install" in
      let python_0install = if Sys.file_exists local_0install then local_0install else "0install" in
      let python_argv = Array.of_list (python_0install :: args) in
      Unix.execvp (python_argv.(0)) python_argv
  | _ -> failwith "No argv[0]"
;;

let () = handle_exceptions main;;
