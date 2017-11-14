(* Copyright (C) 2017, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Platform-specific code for interacting with distribution package managers. *)

(** Create a suitable distribution object for this system. *)
val get_host_distribution : packagekit:(Packagekit.packagekit Lazy.t) -> General.config -> Distro.t

(** {2 The following are exposed only for unit-testing} *)

val generic_distribution : packagekit:Packagekit.packagekit Lazy.t -> General.config -> Distro.distribution

module ArchLinux : sig
  val arch_distribution : ?arch_db:Support.Common.filepath -> packagekit:Packagekit.packagekit Lazy.t -> General.config -> Distro.distribution
end

module Debian : sig
  val debian_distribution : ?status_file:Support.Common.filepath -> packagekit:Packagekit.packagekit Lazy.t -> General.config -> Distro.distribution
end

module RPM : sig
  val rpm_distribution : ?rpm_db_packages:Support.Common.filepath -> packagekit:Packagekit.packagekit Lazy.t -> General.config -> Distro.distribution
end

module Ports : sig
  val ports_distribution : ?pkg_db:Support.Common.filepath -> packagekit:Packagekit.packagekit Lazy.t -> General.config -> Distro.distribution
end

module Gentoo : sig
  val gentoo_distribution : ?pkgdir:Support.Common.filepath -> packagekit:Packagekit.packagekit Lazy.t -> General.config -> Distro.distribution
end

module Slackware : sig
  val slack_distribution : ?packages_dir:Support.Common.filepath -> packagekit:Packagekit.packagekit Lazy.t -> General.config -> Distro.distribution
end

module Mac : sig
  val macports_distribution : ?macports_db:Support.Common.filepath -> General.config -> Distro.distribution
  val darwin_distribution : General.config -> Distro.distribution
end
