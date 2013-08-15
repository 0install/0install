(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Support for internationalisation. *)

(* There is an ocaml-gettext package, but it's hard to install and seems unmaintained. As we don't need much,
   here's a simple implementation. Note: encodings are ignored; we only support UTF-8. *)

open Common

(* Language, country, encoding, variant, e.g. "en_GB.utf-8@foo" *)
let re_locale = Str.regexp "^\\([a-z]+\\)\\([-_][a-z]+\\)?\\([.:].*\\)?\\(@.*\\)?$"

type lang_spec = (string * string option)    (* Langauge, country *)

let parse_lang locale : lang_spec option =
  let s = (String.lowercase locale) in
  if not (Str.string_match re_locale s 0) then (
    log_warning "Failed to parse locale '%s'" locale;
    None
  ) else (
    (* If we cared about the encoding, we would normalise it by removing _ and -. But we don't. *)
    let cc = try Some (Utils.string_tail (Str.matched_group 2 s) 1) with Not_found -> None in
    Some (Str.matched_group 1 s, cc)
  )

let format_lang = function
  | (l, None) -> l
  | (l, Some c) -> l ^ "_" ^ (String.uppercase c)

(** Get the users preferred language(s), most preferred first. The default is always included.
    See: http://www.gnu.org/software/gettext/manual/html_mono/gettext.html#The-LANGUAGE-variable *)
let get_langs ?(default=("en", Some "gb")) (system:system) =
  let lang =
    match system#getenv "LC_ALL" with
    | Some lang -> lang
    | None ->
        match system#getenv "LC_MESSAGES" with
        | Some lang -> lang
        | None ->
          match system#getenv "LANG" with
          | Some lang -> lang
          | None -> "C" in
  let langs =
    if lang = "C" then
      []
    else (
      match system#getenv "LANGUAGE" with
      | Some langs -> Str.split Utils.re_colon langs
      | None -> [lang]
    ) in
  let specs = Utils.filter_map ~f:parse_lang langs in
  if List.mem default specs then specs else specs @ [default]
