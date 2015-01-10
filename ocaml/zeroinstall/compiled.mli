(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Binary implementations that could be created from source ones. *)

(** Return the binary implementation that would be created by compiling the given
 * source. *)
val of_source : host_arch:Arch.arch -> Impl.existing Impl.t ->
  [ `Ok of Impl.generic_implementation
  | `Reject of [> `No_compile_command]
  | `Filtered_out ]   (* We produced a binary not supported by this version of 0install. *)
