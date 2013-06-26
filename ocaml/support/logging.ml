(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Simple logging support *)

type level = Info | Warning

(* [fmt] has type ('a, unit, string, unit) format4, which means:
   - we accept any a format with variables type (e.g. "got:%s" has type string -> unit)
   - any custom print function passed by the caller has type unit -> string
   - the final result of the whole thing is unit
 *)
type 'a log_format = ('a, unit, string, unit) format4

let log level ?ex =
  let do_log s =
    match level with
    | Info ->
        if Printexc.backtrace_status () then
        output_string stderr ("info: " ^ s ^ "\n")
    | Warning ->
        output_string stderr ("warning: " ^ s);
        let () = match ex with
        | None -> ()
        | Some ex ->
            output_string stderr ": ";
            output_string stderr (Printexc.to_string ex);
            if Printexc.backtrace_status () then (
              output_string stderr "\n";
              Printexc.print_backtrace stderr
            ) else ()
        in output_string stderr "\n"
  in
  Printf.ksprintf do_log
;;

(** Write a message to stderr if verbose logging is on. *)
let log_info fmt = log Info fmt

(** Write a message to stderr, prefixed with "warning: ". *)
let log_warning ?ex fmt = log Warning ?ex fmt
