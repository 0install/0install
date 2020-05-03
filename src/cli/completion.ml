(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Tab-completion for command-line arguments *)

open Zeroinstall.General
open Support
open Support.Argparse
open Options
module Apps = Zeroinstall.Apps
module Impl = Zeroinstall.Impl
module Feed = Zeroinstall.Feed
module Feed_cache = Zeroinstall.Feed_cache

let starts_with = XString.starts_with
let slice = Support.Utils.slice

type ctype = Add | Prefix

let list_all_interfaces = Feed_cache.list_all_feeds (* (close enough) *)

(** There is one subclass of this for each supported shell. *)
class virtual completer ~print_endline command config =
  object (self)
    val config = config

    (** Get the information about what to complete from the shell, and put it in a standard format: the index
        of the word to complete and the list of words. Undo any "helpful" preprocessing the shell may have done. *)
    method virtual normalise : string list -> (int * string list)

    (** Get the index of the word to complete, as reported by the shell. This is used internally by [normalise],
        because some shells differ only in the way they count this. *)
    method get_cword =
      let cword = int_of_string (Support.Utils.getenv_ex config.system "COMP_CWORD") - 1 in
      match command with
      | `Install -> cword
      | `Launch -> cword + 1    (* we added "run" at the start *)
      | `Store -> cword + 1    (* we added "store" at the start *)
      | `Desktop -> cword + 1    (* we added "_desktop" at the start *)

    method get_config = config

    (** Tell the shell about a possible match. *)
    method add ctype value =
      match ctype with
      | Add -> print_endline ("add " ^ value)
      | Prefix -> print_endline ("prefix " ^ value)

    (** The word being completed could be an app name. *)
    method add_apps prefix =
      let apps = Apps.list_app_names config in
      let check name =
        if starts_with name prefix then
          self#add Add name in
      List.iter check apps

    (** The word being completed could be a file. *)
    method add_files _prefix =
      print_endline "file"

    (** The word being completed could be an interface. *)
    method add_interfaces prefix =
      let could_be start =
        if String.length start > String.length prefix then starts_with start prefix
        else starts_with prefix start in

      if could_be "http://" || could_be "https://" then (
        let re_start = Str.regexp "^\\(https?://[^/]+/\\).*$" in
        if Str.string_match re_start prefix 0 then (
          let add_if_matches uri =
            if starts_with uri prefix then self#add Add uri in
          XString.Set.iter add_if_matches (list_all_interfaces config)
        ) else (
          (* Start with just the domains *)
          let add_matching_domain uri s =
            if starts_with uri prefix && Str.string_match re_start uri 0 then
              XString.Set.add (Str.matched_group 1 uri) s
            else
              s
          in
          let domains = XString.Set.fold add_matching_domain (list_all_interfaces config) XString.Set.empty in
          List.iter (self#add Prefix) (XString.Set.elements domains)
        )
      );
      let re_scheme_sep = Str.regexp "https?://" in
      if not (Str.string_match re_scheme_sep prefix 0) then
        self#add_files prefix
  end

(* 0install <Tab> *)
let complete_command (completer:completer) raw_options prefix group =
  let add s (name, _values) = XString.Set.add name s in
  let options_used = List.fold_left add XString.Set.empty raw_options in

  let commands = group |> List.filter (fun (full, _) ->
    if prefix = "" then not (XString.starts_with full "_")
    else starts_with full prefix
  ) in
  let compatible_with_command (_name, subcommand) = XString.Set.subset options_used (Command_tree.set_of_option_names subcommand) in
  let valid_commands = List.filter compatible_with_command commands in

  let complete_commands = if List.length valid_commands = 0 then commands else valid_commands in

  List.iter (fun (name, _) -> completer#add Add name) complete_commands

(* 0install config <Tab> *)
let complete_config_option completer pre =
  let add_if_matches name =
    if starts_with name pre then completer#add Add name in
  List.iter add_if_matches ["network_use"; "freshness"; "help_with_testing"; "auto_approve_keys"]

(* 0install config name <Tab> *)
let complete_config_value config completer name pre =
  let add_if_matches value =
    if starts_with value pre then completer#add Add value in
  match name with
  | "network_use" ->
      List.iter add_if_matches ["off-line"; "minimal"; "full"]
  | "help_with_testing" | "auto_approve_keys" ->
      List.iter add_if_matches ["true"; "false"]
  | "freshness" -> (
      match config.freshness with
      | None -> add_if_matches "0"
      | Some freshness -> add_if_matches @@ Conf.format_interval  @@ freshness
  )
  | _ -> ()

(* 0install remove-feed <Tab> *)
let complete_interfaces_with_feeds config completer pre =
  let check_iface uri =
    if starts_with uri pre then (
      let iface_config = Feed_cache.load_iface_config config uri in
      if iface_config.Feed_cache.extra_feeds <> [] then
        completer#add Add uri
    ) in
  XString.Set.iter check_iface (list_all_interfaces config)

(* 0install remove-feed iface <Tab> *)
let complete_extra_feed config completer iface pre =
  let {Feed_cache.extra_feeds; _} = Feed_cache.load_iface_config config iface in
  let add_if_matches feed =
    let url = feed.Zeroinstall.Feed_import.src |> Zeroinstall.Feed_url.format_url in
    if starts_with url pre then
      completer#add Add url
  in
  List.iter add_if_matches extra_feeds

let complete_digest completer pre ~value =
  let add_if_matches name =
    let name = if value then name else String.sub name 0 (String.length name - 1) in
    if starts_with name pre then completer#add (if value then Prefix else Add) name in
  ["sha1="; "sha1new="; "sha256="; "sha256new_"] |> List.iter add_if_matches

(** We are completing an argument, not an option. *)
let complete_arg config (completer:completer) pre = function
  | ["run"] -> completer#add_apps pre; completer#add_interfaces pre; completer#add_files pre
  | "run" :: _ -> completer#add_files pre
  | ["add"; _ ] -> completer#add_interfaces pre
  | ["add-feed"] -> completer#add_interfaces pre
  | ["add-feed"; _iface] -> completer#add_files pre
  | ["config"] -> complete_config_option completer pre
  | ["config"; name] -> complete_config_value config completer name pre
  | ["destroy"] | ["whatchanged"] -> completer#add_apps pre
  | ["digest"] -> completer#add_files pre
  | ["download"] | ["select"] | ["update"] -> completer#add_apps pre; completer#add_interfaces pre
  | ["import"] -> completer#add_files pre
  | ["list-feeds"] -> complete_interfaces_with_feeds config completer pre
  | ["man"] -> completer#add_apps pre
  | ["remove-feed"] -> complete_interfaces_with_feeds config completer pre; completer#add_files pre
  | ["remove-feed"; iface] -> complete_extra_feed config completer iface pre
  | ["show"] -> completer#add_apps pre; completer#add_files pre
  | ["store"; "add"] -> complete_digest completer pre ~value:true
  | ["store"; "add"; _] -> completer#add_files pre
  | ["store"; "copy"] -> completer#add_files pre
  | ["store"; "copy"; _] -> completer#add_files pre
  | ["store"; "optimise"] -> completer#add_files pre
  | ["store"; "audit"] -> completer#add_files pre
  | ["store"; "find"] -> complete_digest completer pre ~value:true
  | ["store"; "manifest"] -> completer#add_files pre
  | ["store"; "manifest"; _] -> complete_digest completer pre ~value:false
  | ["store"; "verify"] -> complete_digest completer pre ~value:true; completer#add_files pre
  | _ -> ()

class bash_completer ~print_endline command config =
  object (self : #completer)
    inherit completer ~print_endline command config as super

    val mutable current = ""

    method normalise args =
      let cword = ref @@ self#get_cword in

      (* Bash does crazy splitting (e.g. "http://foo" becomes "http" ":" "//foo")
         Do our best to reverse that splitting here (inspired by Git completion code) *)

      (* [i] is the index in (the original) args of the next item *)
      let rec fix_splitting i = function
        | a :: ":" :: rest -> (
            if i + 1 = !cword then cword := !cword - 1        (* Tab on the colon *)
            else if i + 1 < !cword then cword := !cword - 2;  (* Tab after the colon *)
            match rest with
            | b :: rest -> (a ^ ":" ^ b) :: fix_splitting (i + 3) rest
            | [] -> [a ^ ":"]
        )
        | a :: "=" :: rest -> (
            if i + 1 < !cword then cword := !cword - 1;  (* Tab after the equals *)
            a :: fix_splitting (i + 2) rest
        )
        | a :: rest -> a :: fix_splitting (i + 1) rest
        | [] -> []
      in
      let args = fix_splitting 0 args in

      current <- if !cword < List.length args then List.nth args !cword else "";

      (!cword, args)

    method! add ctype value =
      let use v =
        match ctype with
        | Prefix -> super#add ctype v
        | Add -> super#add ctype (v ^ " ") in
      try
        let colon_index = String.rindex current ':' in
        let ignored = (String.sub current 0 colon_index) ^ ":" in
        if starts_with value ignored then
          use @@ XString.tail value (colon_index + 1)
        else
          ()
      with Not_found -> use value
      
  end

class fish_completer ~print_endline command config =
  object (self)
    inherit completer ~print_endline command config as super

    val mutable response_prefix = ""

    method normalise args =
      let cword = self#get_cword in
      let current = if cword < List.length args then List.nth args cword else "" in
      if starts_with current "--" then
        match Str.bounded_split_delim XString.re_equals current 2 with
        | [name; _value] as pair ->
            response_prefix <- (name ^ "=");
            (cword + 1, (slice args ~start:0 ~stop:cword) @ pair @ (slice args ~start:cword))
        | _ -> (cword, args)
      else
        (cword, args)

    method! add ctype value = super#add ctype (response_prefix ^ value)
  end

class zsh_completer ~print_endline command config =
  object
    inherit fish_completer ~print_endline command config as super

    method !get_cword = super#get_cword - 1
  end

let complete_version completer ~range ~maybe_app target pre =
  let re_dotdot = Str.regexp_string ".." in
  let config = completer#get_config in
  let uri =
    if maybe_app then (
      match Apps.lookup_app config target with
      | None -> target
      | Some path -> (Apps.get_requirements config.system path).Zeroinstall.Requirements.interface_uri
    ) else target in

  match Zeroinstall.Feed_url.parse uri with
  | `Distribution_feed _ -> ()
  | (`Local_feed _ | `Remote_feed _) as feed ->
      match Feed_cache.get_cached_feed config feed with
      | None -> ()
      | Some feed ->
          let pre = Str.replace_first (Str.regexp_string "\\!") "!" pre in
          let v_prefix =
            if range then
              match Str.bounded_split_delim re_dotdot pre 2 with
              | [start; _] -> start ^ "..!"
              | _ -> ""
            else
              "" in

          let check pv =
            let v = Zeroinstall.Version.to_string pv in
            let vexpr = v_prefix ^ v in
            if starts_with vexpr pre then Some vexpr else None in
          let all_versions = Feed.zi_implementations feed
                             |> XString.Map.map_bindings (fun _k impl -> impl.Impl.parsed_version) in
          let matching_versions = List.filter_map check (List.sort compare all_versions) in
          List.iter (completer#add Add) matching_versions

(* 0install --option=<Tab> *)
let complete_option_value (completer:completer) args (_, handler, values, carg) =
  let pre = List.nth values carg in
  let complete_from_list lst =
    ListLabels.iter lst ~f:(function item ->
      if starts_with item pre then completer#add Add item
    ) in
  let arg_types = handler#get_arg_types (List.length values) in
  match List.nth arg_types carg with
  | Dir -> completer#add_files pre
  | ImplRelPath -> ()
  | CommandName -> ()
  | VersionRange | SimpleVersion as t -> (
      let use ~maybe_app target = complete_version completer ~range:(t = VersionRange) ~maybe_app target pre in
      match carg, args with
      | 1, _ -> use ~maybe_app:false (List.hd values)           (* --version-for iface <Tab> *)
      | _, (_ :: target :: _) -> use ~maybe_app:true target     (* --version <Tab> run foo *)
      | _ -> ()                               (* Don't yet know the iface, so can't complete *)
  )
  | CpuType -> complete_from_list ["src"; "i386"; "i486"; "i586"; "i686"; "ppc"; "ppc64"; "x86_64"]
  | OsType -> complete_from_list ["Cygwin"; "Darwin"; "FreeBSD"; "Linux"; "MacOSX"; "Windows"]
  | Message -> ()
  | HashType -> complete_from_list Zeroinstall.Manifest.algorithm_names
  | IfaceURI -> (
      match args with
      | _ :: app :: _ -> (
        let config = completer#get_config in
        match Apps.lookup_app config app with
        | None -> completer#add_interfaces pre
        | Some path ->
            Apps.get_selections_no_updates config.system path |> Zeroinstall.Selections.iter (fun role _sel ->
              let uri = role.Zeroinstall.Selections.iface in
              if starts_with uri pre then completer#add Add uri
            )
      )
      | _ -> completer#add_interfaces pre
  )

(** Filter the options to include only those compatible with the subcommand. *)
let get_possible_options args node =
  let _, node, _ = Command_tree.lookup node args in
  Command_tree.set_of_option_names node |> XString.Set.elements

let handle_complete ~stdout config = function
  | (shell :: prog :: raw_args) -> (
      let command =
        let prog = Filename.basename prog in
        if starts_with prog "0launch" then `Launch
        else if starts_with prog "0store" then `Store
        else if starts_with prog "0desktop" then `Desktop
        else `Install in
      let print_endline s = Format.fprintf stdout "%s@." s in
      let completer = match shell with
      | "bash" -> new bash_completer ~print_endline command config
      | "fish" -> new fish_completer ~print_endline command config
      | "zsh" -> new zsh_completer ~print_endline command config
      | x -> failwith @@ "Unsupported shell: " ^ x in

      let raw_args =
        match command with
        | `Install -> raw_args
        | `Store -> "store" :: raw_args
        | `Desktop -> "_desktop" :: raw_args
        | `Launch -> "run" :: raw_args in

      let open Cli in
      let (cword, args) = completer#normalise raw_args in
      let args = if cword = List.length args then args @ [""] else args in
      let (raw_options, args, complete) = Support.Argparse.read_args ~cword Cli.spec args in

      match complete with
      | CompleteNothing -> ()
      | CompleteOptionName "-" -> completer#add Prefix "--"   (* Suggest using a long option *)
      | CompleteOptionName prefix ->
          let possible_options = get_possible_options args (Command_tree.Group commands) in
          let check_name name = starts_with name prefix in
          let completions = List.filter check_name possible_options in
          List.iter (completer#add Add) (List.sort compare completions)
      | CompleteOption opt -> complete_option_value completer args opt
      | CompleteArg 0 -> complete_command completer raw_options (List.hd args) Cli.commands
      | CompleteArg 1 when List.hd args = "store" -> complete_command completer raw_options (List.nth args 1) Cli.store_commands
      | CompleteArg i -> complete_arg config completer (List.nth args i) (slice args ~start:0 ~stop:i)
      | CompleteLiteral lit -> completer#add Add lit
  )
  | _ -> failwith "Missing arguments to '0install _complete'"
