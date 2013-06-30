(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing command-line arguments *)

open Options
open General
open Support.Common
open Support.Argparse

let starts_with = Support.Utils.starts_with

let i_ x = x;;

type zi_arg_type =
  | Dir
  | ImplRelPath
  | Command
  | VersionRange
  | SimpleVersion
  | CpuType | OsType
  | Message
  | HashType
  | IfaceURI

(* This is tricky, because --version does two things:
   [0install --version] shows the version of 0install.
   [0install --version=1 run foo] runs version 1 of "foo". *)
let parse_version_option =
  object
    method read _opt_name stream ~completion:_ =
      match Stream.peek stream with
      | None -> []                                (* --version *)
      | Some next when starts_with next "-" -> [] (* --version --verbose *)
      | Some next -> Stream.junk stream; [next]   (* --version 1 *)

    method parse = function
      | [] -> ShowVersion
      | [expr] -> RequireVersion expr
      | _ -> assert false

    method get_arg_types = function
      | [] -> []
      | [_] -> [VersionRange]
      | _ -> assert false

  end

type zi_opt_list = (zi_option, zi_arg_type) opt list

let generic_select_options : zi_opt_list = [
  ([      "--before"],      i_ "choose a version before this",      new one_arg SimpleVersion @@ fun v -> Before v);
  ([      "--command"],     i_ "command to select",                 new one_arg Command @@ fun c -> SelectCommand c);
  ([      "--cpu"],         i_ "target CPU type",                   new one_arg CpuType @@ fun c -> Cpu c);
  ([      "--message"],     i_ "message to display when interacting with user", new one_arg Message @@ fun m -> WithMessage m);
  ([      "--not-before"],  i_ "minimum version to choose",         new one_arg SimpleVersion @@ fun v -> NotBefore v);
  ([      "--os"],          i_ "target operation system type",      new one_arg OsType @@ fun o -> Os o);
  (["-r"; "--refresh"],     i_ "refresh all used interfaces",       new no_arg @@ Refresh);
  (["-s"; "--source"],      i_ "select source code",                new no_arg @@ Source);
  ([      "--version"],     i_ "specify version constraint (e.g. '3' or '3..')", parse_version_option);
  ([      "--version-for"], i_ "set version constraints for a specific interface", new two_arg IfaceURI VersionRange @@ fun u v -> RequireVersionFor(u, v));
]

let offline_options = [
  (["-o"; "--offline"],     i_ "try to avoid using the network",    new no_arg @@ NetworkUse Offline);
]

let digest_options = [
  ([      "--algorithm"], i_ "the hash function to use", new one_arg HashType @@ fun h -> UseHash h);
  (["-m"; "--manifest"],  i_ "print the manifest",       new no_arg ShowManifest);
  (["-d"; "--digest"],    i_ "print the digest",         new no_arg ShowDigest);
]

let xml_output : zi_opt_list = [
  (["--xml"], i_ "print selections as XML", new no_arg ShowXML);
]

let diff_options : zi_opt_list = [
  (["--full"], i_ "show diff of the XML", new no_arg ShowFullDiff);
]

let download_options : zi_opt_list = [
  (["--show"], i_ "show where components are installed", new no_arg ShowHuman);
]

let show_options : zi_opt_list = [
  (["-r"; "--root-uri"], i_ "display just the root interface URI", new no_arg ShowRoot);
]

let run_options : zi_opt_list = [
  (["-m"; "--main"],    i_ "name of the file to execute",           new one_arg ImplRelPath @@ fun m -> MainExecutable m);
  (["-w"; "--wrapper"], i_ "execute program using a debugger, etc", new one_arg Command @@ fun cmd -> Wrapper cmd);
]

let common_options : zi_opt_list = [
  (["-c"; "--console"],    i_ "never use GUI",                     new no_arg @@ UseGUI No);
  ([      "--dry-run"],    i_ "just print what would be executed", new no_arg @@ DryRun);
  (["-g"; "--gui"],        i_ "show graphical policy editor",      new no_arg @@ UseGUI Yes);
  (["-h"; "--help"],       i_ "show this help message and exit",   new no_arg @@ Help);
  (["-v"; "--verbose"],    i_ "more verbose output",               new no_arg @@ Verbose);
  (["-V"; "--version"],    i_ "display version information",       parse_version_option);
  ([      "--with-store"], i_ "add an implementation cache",       new one_arg Dir @@ fun path -> WithStore path);
]

let spec : (zi_option, zi_arg_type) argparse_spec = {
  options_spec = generic_select_options @ offline_options @ digest_options @
                 xml_output @ diff_options @ download_options @ show_options @
                 run_options @ common_options;
  no_more_options = function
    | [_; "run"] | [_; "runenv"] -> true
    | _ -> false;
}

let add_store settings store =
  settings.config.stores <- store :: settings.config.stores;
  log_info "Stores search path is now %s" @@ String.concat path_sep settings.config.stores

let increase_verbosity options =
  options.verbosity <- options.verbosity + 1;
  let open Support.Logging in
  Printexc.record_backtrace true;
  if options.verbosity = 1 then (
    threshold := Info;
    (* Print this as soon as possible once logging is on *)
    log_info "OCaml front-end to 0install: entering main"
  ) else (
    threshold := Debug
  )

let select_options = xml_output @ generic_select_options

(** Which options are valid with which command *)
let command_options = [
  ("add", generic_select_options);
  ("select", select_options);
  ("show", xml_output @ show_options);
  ("download", download_options @ select_options);
  ("run", run_options @ generic_select_options);
  ("update", generic_select_options);
  ("whatchanged", diff_options);
  ("destroy", []);
  ("config", []);
  ("import", []);
  ("list", []);
  ("search", []);
  ("add-feed", offline_options);
  ("remove-feed", offline_options);
  ("list-feeds", []);
  ("man", []);
  ("digest", digest_options);
]

let set_of_option_names opts =
  let add s (names, _help, _handler) = List.fold_right StringSet.add names s in
  List.fold_left add StringSet.empty opts

(* Ensure these options are all valid for the given command. *)
let check_options command_name options =
  let valid_options = set_of_option_names (
    try List.assoc command_name command_options
    with Not_found -> raise_safe "Unknown 0install sub-command '%s': try --help" command_name
  ) in

  let check_opt (name, _value) =
    if not (StringSet.mem name valid_options) then
      raise_safe "Option %s is not valid with command '%s'" name command_name in
  List.iter check_opt options
;;

let parse_args config args =
  let (raw_options, args) = try Support.Argparse.parse_args spec args;
  with Unknown_option opt ->
    log_info "Unknown option '%s'" opt;
    raise Fallback_to_Python in

  (* Default values *)
  let options = {
    config;
    gui = Maybe;
    dry_run = false;
    verbosity = 0;
    extra_options = [];
    args;
  } in

  options.extra_options <- filter_options raw_options (function
    | UseGUI b -> options.gui <- b; true
    | DryRun -> raise Fallback_to_Python
    | Verbose -> increase_verbosity options; true
    | WithStore store -> add_store options store; true
    | ShowVersion -> raise Fallback_to_Python
    | Help -> raise Fallback_to_Python
    | _ -> false
  );

  (* This check is mainly to prevent command_options getting out-of-date *)
  let () = match args with
  | command :: _ -> check_options command options.extra_options
  | [] -> () in

  options
;;
