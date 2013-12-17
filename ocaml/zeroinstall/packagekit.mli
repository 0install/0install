(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interacting with distribution package managers via PackageKit. This is used to find uninstalled candidate packages. *)

type packagekit_id = string
type size = Int64.t

type package_info = {
  version : Versions.parsed_version;
  machine : string option;
  installed : bool;
  retrieval_method : Feed.distro_retrieval_method;
}

type packagekit = <
  (** Check whether PackageKit is available (only slow the first time) *)
  is_available : bool Lwt.t;

  (** Return any cached candidates.
      The candidates are those discovered by a previous call to [check_for_candidates].
      @param package_name the distribution's name for the package *)
  get_impls : string -> package_info list;

  (** Request information about these packages from PackageKit. *)
  check_for_candidates : string list -> unit Lwt.t;

  (** Install packages. Will confirm first with the user. *)
  install_packages : Progress.watcher -> (Feed.implementation * Feed.distro_retrieval_method) list -> [ `ok | `cancel ] Lwt.t;
>

(** Create a packagekit object, which can be used to query the PackageKit D-BUS
 * service for information about (uninstalled) candidate packages.
 * (overridable for unit-tests) *)
val packagekit : (General.config -> packagekit) ref
