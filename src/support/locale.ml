(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Common

(* Language, country, encoding, variant, e.g. "en_GB.utf-8@foo" *)
let re_locale = Str.regexp "^\\([a-z]+\\)\\([-_][a-z]+\\)?\\([.:].*\\)?\\(@.*\\)?$"

type lang_spec = (string * string option)    (* Langauge, country *)

module LangType =
  struct
    type t = lang_spec

    let compare a b = compare a b
  end

module LangMap = Map.Make(LangType)

let parse_lang locale : lang_spec option =
  let s = String.lowercase_ascii locale in
  if not (Str.string_match re_locale s 0) then (
    log_warning "Failed to parse locale '%s'" locale;
    None
  ) else (
    (* If we cared about the encoding, we would normalise it by removing _ and -. But we don't. *)
    let cc = try Some (XString.tail (Str.matched_group 2 s) 1) with Not_found -> None in
    Some (Str.matched_group 1 s, cc)
  )

let format_lang = function
  | (l, None) -> l
  | (l, Some c) -> l ^ "_" ^ String.uppercase_ascii c

(** Get the users preferred language(s), most preferred first. The default is always included.
    See: http://www.gnu.org/software/gettext/manual/html_mono/gettext.html#The-LANGUAGE-variable *)
let get_langs ?(default=("en", Some "gb")) (system:#environment) =
  let get var =
    match system#getenv var with
    | None | Some "" -> None
    | v -> v in

  let lang =
    get "LC_ALL" |? lazy (
    get "LC_MESSAGES" |? lazy (
    get "LANG" |? lazy "C"
    )) in

  let langs =
    if lang = "C" then
      []
    else (
      match system#getenv "LANGUAGE" with
      | Some langs -> Str.split XString.re_colon langs
      | None -> [lang]
    ) in
  let specs = List.filter_map parse_lang langs in
  if List.mem default specs then specs else specs @ [default]

(* Converts a list of languages (most preferred first) to a map from languages to scores.
 * For example, the list ["en_US", "en_GB", "fr"] produces the scores:
 * en_US -> 6
 * en_GB -> 4
 * en    -> 3
 * fr    -> 1
 *)
let score_langs langs =
  let i = ref ((List.length langs * 2) + 2) in
  ListLabels.fold_left ~init:LangMap.empty langs ~f:(fun map lang ->
    if not (LangMap.mem lang map) then (
      i := !i - 2;
      LangMap.add (fst lang, None) (!i - 1) @@
        LangMap.add lang !i map
    ) else map
  )

(* Look up a language string (e.g. from an xml:lang attribute) using a ranking from [rank_langs].
 * If lang is None, we assume English. Returns 0 if there is no match, or a positive number  *)
let score_lang langs lang =
  let lang =
    match lang with
    | None -> "en"
    | Some lang -> lang in
  match parse_lang lang with
  | None -> 0
  | Some lang ->
      try LangMap.find lang langs
      with Not_found ->
        try LangMap.find (fst lang, None) langs
        with Not_found ->
          0
