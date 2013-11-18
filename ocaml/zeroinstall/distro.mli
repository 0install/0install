(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Interacting with distribution package managers. *)

(** Passed to [distribution#get_package_impls]. It provides details of the query and a place to collect the results. *)
class type query =
  object
    method package_name : string
    method elem : Support.Qdom.element
    method props : Feed.properties
    method feed : Feed.feed

    method add_result : string -> Feed.implementation -> unit
    method add_package_implementation :
      id:string ->
      version:string ->
      machine:string ->
      extra_attrs:((string * string) list) ->
      is_installed:bool ->
      distro_name:string ->
      unit
  end

class virtual distribution : General.config ->
  object
    val virtual distro_name : string

    (** All IDs will start with this string (e.g. "package:deb") *)
    val virtual id_prefix : string

    (** Can we use packages for this distribution? For example, MacPortsDistribution can use "MacPorts" and "Darwin" packages. *)
    method match_name : string -> bool

    (** Test whether this <selection> element is still valid. This should only be called by the [Distro.is_installed] function. *)
    method virtual is_installed : Support.Qdom.element -> bool

    (** Add the implementations for this feed to [query].
     * Called by [get_impls_for_feed] once for each <package-implementation> element.
     * This default implementation adds anything found previously by PackageKit. *)
    method private get_package_impls : query -> unit

    (** Get the native implementations (installed or candidates for installation) for this feed.
     * This default implementation finds the best <package-implementation> elements and calls [get_package_impls] on each one. *)
    method get_impls_for_feed : Feed.feed -> Feed.implementation Support.Common.StringMap.t

    (** Check (asynchronously) for available but currently uninstalled candidates. Once the returned
        promise resolves, the candidates should be included in future responses from [get_package_impls]. *)
    method check_for_candidates : Feed.feed -> unit Lwt.t

    (** Install a set of packages of a given type (as set previously by [check_for_candidates]).
     * Normally called only by the [Distro.install_distro_packages] function. *)
    method install_distro_packages : Ui.ui_handler -> string -> (Feed.implementation * Feed.distro_retrieval_method) list -> [ `ok | `cancel ] Lwt.t

    (** Called when an installed package is added, or when installation completes. This is useful to fix up the main value. *)
    method private fixup_main : Feed.properties -> unit
  end

(** Create a suitable distribution object for this system. *)
val get_host_distribution : General.config -> Python.slave -> distribution

(** Check whether this <selection> is still valid. If the quick-test-* attributes are present, we use
    them to check. Otherwise, we call [distribution#is_installed]. *)
val is_installed : General.config -> distribution -> Support.Qdom.element -> bool

(** Install these packages using the distribution's package manager.
 * Sorts the implementations into groups by their type and then calls [distribution#install_distro_packages] once for each group. *)
val install_distro_packages : distribution -> Ui.ui_handler -> Feed.implementation list -> [ `ok | `cancel ] Lwt.t


(** {2 The following are exposed only for unit-testing} *)

val generic_distribution : Python.slave -> distribution

module ArchLinux : sig
  val arch_distribution : ?arch_db:Support.Common.filepath -> General.config -> distribution
end

module Debian : sig
  val debian_distribution : ?status_file:Support.Common.filepath -> General.config -> Python.slave -> distribution
end

module RPM : sig
  val rpm_distribution : ?status_file:Support.Common.filepath -> General.config -> Python.slave -> distribution
end

module Ports : sig
  val ports_distribution : ?pkgdir:Support.Common.filepath -> General.config -> Python.slave -> distribution
end

module Gentoo : sig
  val gentoo_distribution : ?pkgdir:Support.Common.filepath -> General.config -> Python.slave -> distribution
end

module Slackware : sig
  val slack_distribution : ?packages_dir:Support.Common.filepath -> General.config -> Python.slave -> distribution
end

module Mac : sig
  val macports_distribution : ?macports_db:Support.Common.filepath -> General.config -> Python.slave -> distribution
  val darwin_distribution : General.config -> Python.slave -> distribution
end
