(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Tab-completion for command-line arguments *)

open General
open Support.Common
open Support.Argparse

let starts_with = Support.Utils.starts_with

let slice ~start ?stop lst =
  let from_start =
    let rec skip lst = function
      | 0 -> lst
      | i -> match lst with
          | [] -> failwith "list too short"
          | (_::xs) -> skip xs (i - 1)
    in skip lst start in
  match stop with
  | None -> from_start
  | Some stop ->
      let rec take lst = function
        | 0 -> []
        | i -> match lst with
            | [] -> failwith "list too short"
            | (x::xs) -> x :: take xs (i - 1)
      in take lst (stop - start)
;;

type ctype = Add | Prefix

class virtual completer config =
  object (self)
    val config = config

    method virtual normalise : string list -> (int * string list)

    method add ctype value =
      match ctype with
      | Add -> print_endline ("add " ^ value)
      | Prefix -> print_endline ("prefix " ^ value)

    method add_apps prefix =
      let apps = Apps.list_app_names config in
      let check name =
        if starts_with name prefix then
          self#add Add name in
      List.iter check apps

    method add_files _prefix =
      print_endline "file"

    method get_cword () =
      int_of_string (Support.Utils.getenv_ex config.system "COMP_CWORD") - 1

    method add_interfaces prefix =
      let could_be start =
        if String.length start > String.length prefix then starts_with start prefix
        else starts_with prefix start in

      if could_be "http://" || could_be "https://" then (
        let re_start = Str.regexp "^\\(https?://[^/]+/\\).*$" in
        if Str.string_match re_start prefix 0 then (
          let add_if_matches uri =
            if starts_with uri prefix then self#add Add uri in
          StringSet.iter add_if_matches (Feed_cache.list_all_interfaces config)
        ) else (
          (* Start with just the domains *)
          let add_matching_domain uri s =
            if starts_with uri prefix && Str.string_match re_start uri 0 then
              StringSet.add (Str.matched_group 1 uri) s
            else
              s
          in
          let domains = StringSet.fold add_matching_domain (Feed_cache.list_all_interfaces config) StringSet.empty in
          List.iter (self#add Prefix) (StringSet.elements domains)
        )
      ) else (
        let re_scheme_sep = Str.regexp "://" in
        if not (Str.string_match re_scheme_sep prefix 0) then
          self#add_files prefix
      )

  end

let complete_command (completer:completer) raw_options prefix =
  let add s (name, _handler, _values) = StringSet.add name s in
  let options_used = List.fold_left add StringSet.empty raw_options in

  let commands = List.filter (fun (full, _) -> starts_with full prefix) Cli.command_options in
  let compatible_with_command (_name, opts) = StringSet.subset options_used (Cli.set_of_option_names opts) in
  let valid_commands = List.filter compatible_with_command commands in

  let complete_commands = if List.length valid_commands = 0 then commands else valid_commands in

  List.iter (fun (name, _) -> completer#add Add name) complete_commands
;;

let complete_arg (completer:completer) pre = function
  | ["run"] -> completer#add_apps pre; completer#add_interfaces pre; completer#add_files pre
  | ["add"] -> completer#add_interfaces pre
  | ["add-feed"] -> completer#add_interfaces pre
  | ["add-feed"; _iface] -> completer#add_files pre
  | ["config"] -> raise Fallback_to_Python;
  | ["destroy"] | ["whatchanged"] -> completer#add_apps pre
  | ["digest"] -> completer#add_files pre
  | ["download"] | ["select"] | ["update"] -> completer#add_apps pre; completer#add_interfaces pre
  | ["import"] -> completer#add_files pre
  | ["list-feeds"] -> raise Fallback_to_Python;
  | ["man"] -> completer#add_apps pre
  | ["remove-feed"] -> raise Fallback_to_Python;
  | ["remove-feed"; _iface] -> raise Fallback_to_Python;
  | ["show"] -> completer#add_apps pre; completer#add_files pre
  | _ -> ()

let string_tail s i =
  let len = String.length s in
  if i > len then failwith ("String '" ^ s ^ "' too short to split at " ^ (string_of_int i))
  else String.sub s i (len - i)

class bash_completer config =
  object (self : #completer)
    inherit completer config as super

    val mutable current = ""

    method normalise args =
      let cword = ref @@ self#get_cword () in

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
          use @@ string_tail value (colon_index + 1)
        else
          ()
      with Not_found -> use value
      
  end

class fish_completer config =
  object (self)
    inherit completer config as super

    val mutable response_prefix = ""

    method normalise args =
      let cword = self#get_cword () in
      let current = if cword < List.length args then List.nth args cword else "" in
      if starts_with current "--" then
        match Str.bounded_split_delim re_equals current 2 with
        | [name; _value] as pair ->
            response_prefix <- (name ^ "=");
            (cword + 1, (slice args ~start:0 ~stop:cword) @ pair @ (slice args ~start:cword))
        | _ -> (cword, args)
      else
        (cword, args)

    method! add ctype value = super#add ctype (response_prefix ^ value)
  end

class zsh_completer config =
  object
    inherit fish_completer config as super

    method !get_cword () = super#get_cword () - 1
  end

let complete_option_value (completer:completer) (_, handler, values, carg) =
  let pre = List.nth values carg in
  let arg_types = handler#get_arg_types values in
  let open Cli in

  match List.nth arg_types carg with
  | Dir -> completer#add_files pre
  | ImplRelPath -> raise Fallback_to_Python
  | Command -> raise Fallback_to_Python
  | VersionRange -> raise Fallback_to_Python
  | SimpleVersion -> raise Fallback_to_Python
  | CpuType | OsType -> raise Fallback_to_Python
  | Message -> ()
  | HashType -> raise Fallback_to_Python
  | IfaceURI -> raise Fallback_to_Python  (* The Python is smarter than just listing all interfaces *)

let handle_complete config = function
  | (shell :: _0install :: raw_args) -> (
      let completer = match shell with
      | "bash" -> new bash_completer config
      | "fish" -> new fish_completer config
      | "zsh" -> new zsh_completer config
      | x -> failwith @@ "Unsupported shell: " ^ x in

      let open Cli in
      let (cword, args) = completer#normalise raw_args in
      let args = if cword = List.length args then args @ [""] else args in
      let (raw_options, args, complete) = Support.Argparse.read_args ~cword spec args in

      match complete with
      | CompleteNothing -> ()
      | CompleteOptionName "-" -> completer#add Prefix "--"   (* Suggest using a long option *)
      | CompleteOptionName prefix ->
          let possible_options = match args with
          | cmd :: _ -> (
              try (List.assoc cmd command_options) @ common_options
              with Not_found -> spec.options_spec
          )
          | _ -> spec.options_spec in
          let check_name name =
            if starts_with name prefix then completer#add Add name in
          let check_opt (names, _help, _handler) =
            List.iter check_name names in
          List.iter check_opt possible_options
      | CompleteOption opt -> complete_option_value completer opt
      | CompleteArg 0 -> complete_command completer raw_options (List.hd args)
      | CompleteArg i -> complete_arg completer (List.nth args i) (slice args ~start:0 ~stop:i)
      | CompleteLiteral lit -> completer#add Add lit
  )
  | _ -> failwith "Missing arguments to '0install _complete'"
