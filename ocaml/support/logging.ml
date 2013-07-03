(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Simple logging support *)

type level = Debug | Info | Warning

let threshold = ref Warning

class type handler =
  object
    method handle : ?ex:exn -> level -> string -> unit
  end

let console_handler =
  object (_ : handler)
    method handle ?ex level msg =
      match level with
      | Debug ->
          output_string stderr ("debug: " ^ msg ^ "\n");
          flush stderr
      | Info ->
          output_string stderr ("info: " ^ msg ^ "\n");
          flush stderr
      | Warning ->
          output_string stderr ("warning: " ^ msg);
          let () = match ex with
          | None -> ()
          | Some ex ->
              output_string stderr ": ";
              output_string stderr (Printexc.to_string ex);
              if Printexc.backtrace_status () then (
                output_string stderr "\n";
                Printexc.print_backtrace stderr
              ) else ()
          in
          output_string stderr "\n";
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
;;

(** Write a message to stderr if verbose logging is on. *)
let log_info fmt = log Info fmt

(** Write a message to stderr, prefixed with "warning: ". *)
let log_warning ?ex fmt = log Warning ?ex fmt
