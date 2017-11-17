(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

type level = Debug | Info | Warning

type time = float

type entry = time * exn option * level * string

type crash_log = {
  crash_handler : entry list -> unit;
  mutable entries : entry list;
}

let crash_log = ref None

let set_crash_logs_handler crash_handler =
  crash_log := Some { crash_handler; entries = [] }

let dump_crash_log ?ex () =
  match !crash_log with
  | None | Some {entries = []; _} -> ()
  | Some crash_log ->
      crash_log.entries <- (Unix.gettimeofday (), ex, Warning, "Dumping crash log") :: crash_log.entries;
      crash_log.crash_handler crash_log.entries;
      crash_log.entries <- []

let string_of_level = function
  | Debug -> "debug"
  | Info -> "info"
  | Warning -> "warning"

let threshold = ref Warning

let clear_fn = ref None

let will_log level = level >= !threshold

type handler = ?ex:exn -> level -> string -> unit

let console_handler ?ex level msg =
  begin match !clear_fn with
  | None -> ()
  | Some fn ->
      fn ();
      clear_fn := None end;

  let term = if ex = None then "\n" else ": " in
  output_string stderr (string_of_level level ^ ": " ^ msg ^ term);
  let () =
    match ex with
    | None -> ()
    | Some ex ->
        output_string stderr (Printexc.to_string ex);
        if Printexc.backtrace_status () then (
          output_string stderr "\n";
          Printexc.print_backtrace stderr
        );
        output_string stderr "\n" in
  flush stderr

let handler = ref console_handler

let log level ?ex fmt =
  Format.kasprintf (fun msg ->
    if level >= !threshold then
      !handler ?ex level msg;
    match !crash_log with
    | None -> ()
    | Some crash_log ->
        crash_log.entries <- (Unix.gettimeofday (), ex, level, msg) :: crash_log.entries;
        if level >= Warning then dump_crash_log ()
  ) fmt

let log_debug ?ex fmt = log Debug ?ex fmt

(** Write a message to stderr if verbose logging is on. *)
let log_info ?ex fmt = log Info ?ex fmt

(** Write a message to stderr, prefixed with "warning: ". *)
let log_warning ?ex fmt = log Warning ?ex fmt

let format_argv_for_logging argv =
  let re_safe_arg = Str.regexp "^[-./a-zA-Z0-9:;,@_]+$" in

  let format_arg arg =
    if Str.string_match re_safe_arg arg 0 then
      arg
    else
      "\"" ^ (String.escaped arg) ^ "\"" in
  String.concat " " (List.map format_arg argv)
