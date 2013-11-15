(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

type level = Debug | Info | Warning

let string_of_level = function
  | Debug -> "debug"
  | Info -> "info"
  | Warning -> "warning"

let threshold = ref Warning

let clear_fn = ref None

let will_log level = level >= !threshold

class type handler =
  object
    method handle : ?ex:exn -> level -> string -> unit
  end

let console_handler =
  object (_ : handler)
    method handle ?ex level msg =

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
  end

let handler = ref console_handler

(* [fmt] has type ('a, unit, string, unit) format4, which means:
   - we accept any a format with variables type (e.g. "got:%s" has type string -> unit)
   - any custom print function passed by the caller has type unit -> string
   - the final result of the whole thing is unit
 *)

let log level ?ex =
  let do_log msg =
    if level >= !threshold then
      !handler#handle ?ex level msg
  in
  Printf.ksprintf do_log

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
