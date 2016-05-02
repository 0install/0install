(* Copyright (C) 2016, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** There are several different versions of the PackageKit API.
    This module provides a consistent interface to them. *)

module Transaction : sig
  type t

  val monitor : t -> switch:Lwt_switch.t -> int32 React.signal Lwt.t
  (** [monitor t ~switch] is a signal giving the percentage complete for the transaction. *)

  val cancel : t -> unit Lwt.t
  (** [cancel t] asks PackageKit to cancel the transaction. *)

  val install_packages : t -> string list -> unit Lwt.t
  (** [install_packages t ids] installs the packages with the given package IDs. *)
end

type t
val connect : Support.Locale.lang_spec -> [`Ok of t | `Unavailable of string] Lwt.t
val summaries : t -> package_names:string list -> (package_id:string -> summary:string -> unit) -> unit Lwt.t
val sizes : t -> package_ids:string list -> (package_id:string -> size:int64 -> unit) -> unit Lwt.t
val run_transaction : t -> (Lwt_switch.t -> Transaction.t -> unit Lwt.t) -> unit Lwt.t
