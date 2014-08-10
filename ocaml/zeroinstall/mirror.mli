(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Support functions for using mirror servers *)

(** Get a recipe for the tar.bz2 of the implementation at the mirror.
 * @return a recipe for a single archive containing the whole implementation.
 * Note: This is just one way we try the mirror. You can also use [for_archive]
 * to check for mirrored copies of individual archives. *)
val for_impl : General.config -> _ Impl.t -> Recipe.t option

(** Return the URL to check for a mirror of an archive URL. *)
val for_archive : General.config -> string -> string option

(** Return the URL to check for a mirror of a feed. *)
val for_feed : General.config -> Feed_url.remote_feed -> string option
