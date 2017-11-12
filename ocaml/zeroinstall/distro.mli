(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Generic code for interacting with distribution package managers. *)

(** Passed to [distribution#get_package_impls]. It provides details of the query and a place to collect the results. *)
type query = {
  elem : [`Package_impl] Element.t; (* The <package-element> which generated this query *)
  package_name : string;            (* The 'package' attribute on the <package-element> *)
  elem_props : Impl.properties;     (* Properties on or inherited by the <package-element> - used by [add_package_implementation] *)
  feed : Feed.feed;                 (* The feed containing the <package-element> *)
  results : Impl.distro_implementation Support.Common.StringMap.t ref;
  problem : string -> unit;
}

type quick_test_condition = Exists | UnchangedSince of float
type quick_test = (Support.Common.filepath * quick_test_condition)

(** Each distribution provides an object of this type, which provides the distribution-specific glue for 0install. *)
class type virtual provider =
  object
    (** Can we use packages for this distribution? For example, MacPortsDistribution can use "MacPorts" and "Darwin" packages. *)
    method match_name : string -> bool

    (** Test whether this <selection> element is still valid. The default implementation tries to load the feed from the
     * feed cache, calls [distribution#get_impls_for_feed] on it and checks whether the required implementation ID is in the
     * returned map. Override this if you can provide a more efficient implementation. *)
    method is_installed : Selections.selection -> bool

    (** Get the native implementations (installed or candidates for installation) for this feed.
     * This default implementation finds the best <package-implementation> elements and calls [get_package_impls] on each one.
     * @param init add the results to this map, rather than starting with an empty one
     * @param problem called to add warnings or notes about problems, for diagnostics *)
    method get_impls_for_feed :
      ?init:(Impl.distro_implementation Support.Common.StringMap.t) ->
      problem:(string -> unit) ->
      Feed.feed ->
      Impl.distro_implementation Support.Common.StringMap.t

    (** Check (asynchronously) for available but currently uninstalled candidates. Once the returned
        promise resolves, the candidates should be included in future responses from [get_package_impls]. *)
    method virtual check_for_candidates : 'a. ui:(#Packagekit.ui as 'a) -> Feed.feed -> unit Lwt.t

    (** Install a set of packages of a given type (as set previously by [check_for_candidates]).
     * Normally called only by the [Distro.install_distro_packages] function.
     * The default implementation tells the user to install them manually using [Impl.distro_retrieval_method]. *)
    method install_distro_packages : 'a. (#Packagekit.ui as 'a) -> string -> (Impl.distro_implementation * Impl.distro_retrieval_method) list -> [ `Ok | `Cancel ] Lwt.t

    (** Check whether this name is possible for this distribution. The default implementation filters using [valid_package_name]. *)
    method is_valid_package_name : string -> bool
  end

(** A convenient base-class which implementations may like to inherit from. *)
class virtual distribution : General.config ->
  object
    inherit provider

    (** Only <package-implementation>s whose names match this regexp will be considered.
     * The default disallows names starting with '.' or '-' or containing '/', to avoid potential problems with
     * shell commands and path lookups. *)
    val valid_package_name : Str.regexp

    (* Should we check for Python and GObject manually? Use [false] if the package manager
     * can be relied upon to find them. *)
    val virtual check_host_python : bool

    val virtual distro_name : string

    (** All IDs will start with this string (e.g. "package:deb") *)
    val virtual id_prefix : string

    (** Paths to search for missing binaries (i.e. the platform default for $PATH) *)
    val system_paths : string list

    (** Sometimes we don't know the correct path for a binary until the package is installed.
     * Called by [add_package_implementation] when the package is already installed and may also be
     * used by [install_distro_packages] when a package becomes installed.
     * The default implementation checks for a "run" command and calls
     * [get_correct_main] to get the correct value. *)
    method private fixup_main : Impl.distro_implementation -> unit

    (** Add the implementations for this feed to [query].
     * Called by [get_impls_for_feed] once for each <package-implementation> element. *)
    method virtual private get_package_impls : query -> unit

    (** Called when an installed package is added, or when installation completes, to find the correct main value,
     * since we might not be able to work it out before-hand. The default checks that the path exists and, if not,
     * searches [system_paths] for it.
     * Note: Only called if the implementation already has a "run" command. *)
    method private get_correct_main : Impl.distro_implementation -> Impl.command -> Support.Common.filepath option

    (** Add a new Feed.implementation result to [query]. *)
    method private add_package_implementation :
      ?id:string ->
      ?main:string ->
      query ->
      version:Version.t ->
      machine:(Arch.machine option) ->
      quick_test:(quick_test option) ->  (* The result is valid while this condition holds *)
      package_state:Impl.package_state ->
      distro_name:string ->
      unit
  end

(** Return the <package-implementation> elements that best match this distribution. *)
val get_matching_package_impls : #distribution -> Feed.feed -> ([`Package_impl] Element.t * Impl.properties) list

(** {2 API for users of the distribution abstraction.} *)

type t

(** [of_provider p] is a distribution implemented by [p]. *)
val of_provider : #provider -> t

(** Get the native implementations (installed or candidates for installation) for this feed.
    @param init add the results to this map, rather than starting with an empty one
    @param problem called to add warnings or notes about problems, for diagnostics *)
val get_impls_for_feed : t -> 
  ?init:(Impl.distro_implementation Support.Common.StringMap.t) ->
  problem:(string -> unit) ->
  Feed.feed ->
  Impl.distro_implementation Support.Common.StringMap.t

(** Check (asynchronously) for available but currently uninstalled candidates. Once the returned
    promise resolves, the candidates will be included in future responses from [get_impls_for_feed]. *)
val check_for_candidates : t -> ui:#Packagekit.ui -> Feed.feed -> unit Lwt.t

(** Install these packages using the distribution's package manager. *)
val install_distro_packages : t -> #Packagekit.ui -> Impl.distro_implementation list -> [ `Ok | `Cancel ] Lwt.t

(** Check whether this <selection> is still valid. If the quick-test-* attributes are present, we use
    them to check. Otherwise, we call [t#is_installed]. *)
val is_installed : t -> General.config -> Selections.selection -> bool
