(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interacting with distribution package managers via PackageKit. This is used to find uninstalled candidate packages. *)

type packagekit_id = string
type size = Int64.t

type package_info = {
  version : Version.t;
  machine : Arch.machine option;
  installed : bool;
  retrieval_method : Impl.distro_retrieval_method;
}

type query_result = {
  results : package_info list;
  problems : string list;
}

class type ui =
  object
    method monitor : Downloader.download -> unit
    method confirm : string -> [`Ok | `Cancel] Lwt.t
    method impl_added_to_store : unit
  end

type packagekit = <
  (* Check whether PackageKit is available (only slow the first time) *)
  status : [`Ok | `Unavailable of string] Lwt.t;

  (* Return any cached candidates.
      The candidates are those discovered by a previous call to [check_for_candidates].
      @param package_name the distribution's name for the package *)
  get_impls : string -> query_result;

  (* Request information about these packages from PackageKit. *)
  check_for_candidates : 'a. ui:(#ui as 'a) -> hint:string -> string list -> unit Lwt.t;

  (* Install packages. Will confirm first with the user. *)
  install_packages : 'a. (#ui as 'a) -> (Impl.distro_implementation * Impl.distro_retrieval_method) list -> [ `Ok | `Cancel ] Lwt.t;
>

(** Create a packagekit object, which can be used to query the PackageKit D-BUS
 * service for information about (uninstalled) candidate packages. *)
val make : Support.Locale.lang_spec -> packagekit
