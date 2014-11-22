(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Implementation mode:
  *
  * `immediate:
  *     an implementation that is ready to run
  *
  * `requires_compilation:
  *     an implementation which requires compilation
  *     before it can be used.
  *
  *)

type t = [`immediate | `requires_compilation]

let to_string = function
  | `immediate -> "immediate"
  | `requires_compilation -> "requires_compilation"

let parse = function
  | "immediate" -> `immediate
  | "requires_compilation" -> `requires_compilation
  | other ->
      Support.Logging.log_warning "Unknown mode '%s'" other;
      `immediate
