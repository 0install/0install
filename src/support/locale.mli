(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Support for internationalisation. *)

(* There is an ocaml-gettext package, but it's hard to install and seems unmaintained. As we don't need much,
   here's a simple implementation. Note: encodings are ignored; we only support UTF-8. *)

type lang_spec = (string * string option)    (* Langauge, country *)

module LangMap : (Map.S with type key = lang_spec)

val parse_lang : string -> lang_spec option

val format_lang : lang_spec -> string

(** Get the user's preferred language(s), most preferred first. The default is always included.
    See: http://www.gnu.org/software/gettext/manual/html_mono/gettext.html#The-LANGUAGE-variable *)
val get_langs : ?default:lang_spec -> #Common.environment -> lang_spec list

(* Converts a list of languages (most preferred first) to a map from languauges to scores.
 * For example, the list ["en_US", "en_GB", "fr"] produces the scores:
 * en_US -> 6
 * en_GB -> 4
 * en    -> 3
 * fr    -> 1
 *)
val score_langs : lang_spec list -> int LangMap.t

(* Look up a language string (e.g. from an xml:lang attribute) using a ranking from [score_langs].
 * If lang is None, we assume English. Returns 0 if there is no match, or a positive number  *)
val score_lang : int LangMap.t -> string option -> int
