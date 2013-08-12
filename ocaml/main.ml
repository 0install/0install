(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The main executable *)

open General
open Support.Common
open Options

let is_option x = String.length x > 0 && x.[0] = '-';;

(* We can't handle any of these at the moment, so pass them to the Python. *)
let is_url url =
  let starts = Support.Utils.starts_with url in
  starts "http://" || starts "https://" || starts "file:" || starts "alias:"
;;

(** Run "python -m zeroinstall.cmd". If ../zeroinstall exists, put it in PYTHONPATH,
    otherwise use the system version of 0install. *)
let fallback_to_python config args =
  let try_with path =
    if config.system#file_exists path then (
      (* Note: on Windows, we need to specify "python" *)
      config.system#exec ~search_path:true ("python" :: path :: "--python-fallback" :: args)
    ) in
  let my_dir = Filename.dirname config.abspath_0install in
  try_with @@ my_dir +/ "0launch";                   (* When installed in /usr/bin *)
  let parent_dir = Filename.dirname my_dir in
  try_with @@ parent_dir +/ "0launch";  (* When running from ocaml directory *)
  try_with @@ Filename.dirname parent_dir +/ "0launch";  (* When running from _build directory *)
  failwith "Can't find 0launch command!"
;;

let handle_run options args : unit =
  let config = options.config in
  if options.gui = Yes then raise Fallback_to_Python;
  let wrapper = ref None in
  Support.Argparse.iter_options options.extra_options (function
    | Wrapper w -> wrapper := Some w
    | ShowManifest -> raise_safe "The -m argument is ambiguous before the 'run' argument. Put it after, or use --main"
    | _ -> raise Fallback_to_Python
  );
  match args with
  | prog :: run_args when not (is_option prog) && not (is_url prog) -> (
      let sels = match Apps.lookup_app config prog with
      | None -> (
          let root = Support.Qdom.parse_file config.system prog in
          match ZI.tag root with
          | None -> Support.Qdom.raise_elem "Not a 0install document (wrong namespace on root element): " root
          | Some "selections" -> root
          | Some "interface" | Some "feed" -> raise Fallback_to_Python
          | Some x -> raise_safe "Unexpected root element <%s>" x
      )
      | Some app_path -> Apps.get_selections_may_update config (Lazy.force options.distro) app_path in
      try Run.execute_selections config sels run_args ?wrapper:!wrapper
      with Safe_exception _ as ex -> reraise_with_context ex "... running %s" prog
    )
  | _ -> raise Fallback_to_Python
;;

let main (system:system) : unit =
  let argv = Array.to_list (system#argv ()) in
  let config = Config.get_default_config system (List.hd argv) in
  match List.tl argv with
  | "_complete" :: args -> Completion.handle_complete config args
  | "runenv" :: runenv_args -> Run.runenv system runenv_args
  | raw_args ->
      try
        let options =
          try Cli.parse_args config raw_args
          with Safe_exception _ as ex ->
            reraise_with_context ex "... processing command line: %s" (String.concat " " argv)
        in
        try
          match options.args with
          | ("run" :: run_args) -> handle_run options run_args
          | ("select" :: args) -> Select.handle options args
          | ("show" :: args) -> Show.handle options args
          | _ -> raise Fallback_to_Python
        with Support.Argparse.Usage_error -> Cli.show_usage_error options
      with Fallback_to_Python ->
        log_info "Can't handle this case; switching to Python version...";
        fallback_to_python config (List.tl argv)

let start system =
  Support.Utils.handle_exceptions main system

let start_if_not_windows system =
  if Sys.os_type <> "Win32" then (
    start system;
    exit 0
  )
