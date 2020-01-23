(* Copyright (C) 2017, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Generic code for interacting with distribution package managers. *)

module Query : sig
  type t
  (** Details of a query and a place to collect the results. *)

  val package : t -> string
  (** [package t] is the name of the package being queried. *)

  val problem : t -> ('a, Format.formatter, unit) format -> 'a
  (** Add a warning message to the query. *)

  val add_result : t -> string -> Impl.distro_implementation -> unit
  (** [add_result t id impl] adds [id -> impl] to the result map. *)

  val results : t -> Impl.distro_implementation Support.XString.Map.t
  (** [results t] is the current results of the query. *)
end

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
     * @param problem called to add warnings or notes about problems, for diagnostics *)
    method get_impls_for_feed :
      problem:(string -> unit) ->
      Feed.t ->
      Impl.distro_implementation Support.XString.Map.t

    (** Check (asynchronously) for available but currently uninstalled candidates. Once the returned
        promise resolves, the candidates should be included in future responses from [get_package_impls]. *)
    method virtual check_for_candidates : 'a. ui:(#Packagekit.ui as 'a) -> Feed.t -> unit Lwt.t

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
    method virtual private get_package_impls : Query.t -> unit

    (** Called when an installed package is added, or when installation completes, to find the correct main value,
     * since we might not be able to work it out before-hand. The default checks that the path exists and, if not,
     * searches [system_paths] for it.
     * Note: Only called if the implementation already has a "run" command. *)
    method private get_correct_main : Impl.distro_implementation -> Impl.command -> Support.Common.filepath option

    (** Add a new Feed.implementation result to [query]. *)
    method private add_package_implementation :
      ?id:string ->
      ?main:string ->
      Query.t ->
      version:Version.t ->
      machine:(Arch.machine option) ->
      quick_test:(quick_test option) ->  (* The result is valid while this condition holds *)
      package_state:Impl.package_state ->
      distro_name:string ->
      unit
  end

(** Return the <package-implementation> elements that best match this distribution. *)
val get_matching_package_impls : #distribution -> Feed.t -> ([`Package_impl] Element.t * Impl.properties) list

(** {2 API for users of the distribution abstraction.} *)

type t

(** [of_provider p] is a distribution implemented by [p]. *)
val of_provider : #provider -> t

(** Get the native implementations (installed or candidates for installation) for this feed.
    @param problem called to add warnings or notes about problems, for diagnostics *)
val get_impls_for_feed : t -> 
  problem:(string -> unit) ->
  Feed.t ->
  Impl.distro_implementation Support.XString.Map.t

(** Check (asynchronously) for available but currently uninstalled candidates. Once the returned
    promise resolves, the candidates will be included in future responses from [get_impls_for_feed]. *)
val check_for_candidates : t -> ui:#Packagekit.ui -> Feed.t -> unit Lwt.t

(** Install these packages using the distribution's package manager. *)
val install_distro_packages : t -> #Packagekit.ui -> Impl.distro_implementation list -> [ `Ok | `Cancel ] Lwt.t

(** Check whether this <selection> is still valid. If the quick-test-* attributes are present, we use
    them to check. Otherwise, we call [t#is_installed]. *)
val is_installed : t -> General.config -> Selections.selection -> bool
