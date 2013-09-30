(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Unpacking archives *)

type mime_type = string

(* Guess the MIME type from the URL's extension.
 * @raise Safe_exception if the extension is unknown. *)
val type_from_url : string -> mime_type

(* Check we have the needed software to extract from an archive of the given type.
 * @raise Safe_exception with a suitable message if not. *)
val check_type_ok : Support.Common.system -> mime_type -> unit
