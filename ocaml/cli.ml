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
    method read _opt_name _command stream ~completion:_ =
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

let parse_r =
  let resolve = function
    | "show" -> ShowRoot
    | _ -> Refresh in

  object
    inherit [zi_option, zi_arg_type] no_arg (AmbiguousOption resolve)
  end

(* -m might or might not take an argument. Very tricky! *)
let parse_m =
  object
    method read opt_name command stream ~completion:_ =
      let is_main () =
        match Stream.peek stream with
        | Some next -> Stream.junk stream; [next]
        | None -> [] in

      match opt_name with
      | "--main" -> is_main ()
      | "--manifest" -> []
      | "-m" -> (
        match command with
        | Some "run" -> is_main ()
        | _ -> []   (* Not "run", or before the subcommand; assume --manifest *)
      )
      | _ -> assert false

    method parse = function
      | [] -> ShowManifest
      | [main] -> MainExecutable main
      | _ -> assert false

    method get_arg_types = function
      | [] -> []
      | [_] -> [ImplRelPath]
      | _ -> assert false
  end

let parse_version_for =
  object
    inherit [zi_option, zi_arg_type] two_arg IfaceURI VersionRange (fun u v -> RequireVersionFor(u, v)) as super

    method! read opt_name command stream ~completion =
      let as_super () = super#read opt_name command stream ~completion in
      if completion <> Some 0 then as_super ()
      else (
        (* When completing the first arg, the second arg might not have been added yet. But it's helpful to
           parse the rest of the command correctly, so we can get the app name. So, only consume the second
           argument if it looks like a version number. *)
        match Stream.npeek 2 stream with
        | [x; v] when String.length v > 0 ->
            if v.[0] >= '0' && v.[0] <= '9' then as_super ()
            else (
              Stream.junk stream;
              [x; ""]
            )
        | _ -> as_super ()
      )
  end

let generic_select_options : zi_opt_list = [
  ([      "--before"],      i_ "choose a version before this",      new one_arg SimpleVersion @@ fun v -> Before v);
  ([      "--command"],     i_ "command to select",                 new one_arg Command @@ fun c -> SelectCommand c);
  ([      "--cpu"],         i_ "target CPU type",                   new one_arg CpuType @@ fun c -> Cpu c);
  ([      "--message"],     i_ "message to display when interacting with user", new one_arg Message @@ fun m -> WithMessage m);
  ([      "--not-before"],  i_ "minimum version to choose",         new one_arg SimpleVersion @@ fun v -> NotBefore v);
  ([      "--os"],          i_ "target operation system type",      new one_arg OsType @@ fun o -> Os o);
  (["-r"; "--refresh"],     i_ "refresh all used interfaces",       parse_r);
  (["-s"; "--source"],      i_ "select source code",                new no_arg @@ Source);
  ([      "--version"],     i_ "specify version constraint (e.g. '3' or '3..')", parse_version_option);
  ([      "--version-for"], i_ "set version constraints for a specific interface", parse_version_for);
]

let offline_options = [
  (["-o"; "--offline"],     i_ "try to avoid using the network",    new no_arg @@ NetworkUse Offline);
]

let update_options = [
  ([      "--background"],  i_ "",                        new no_arg @@ Background);
]

let digest_options = [
  ([      "--algorithm"], i_ "the hash function to use", new one_arg HashType @@ fun h -> UseHash h);
  (["-m"; "--manifest"],  i_ "print the manifest",       parse_m);
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
  (["-r"; "--root-uri"], i_ "display just the root interface URI", parse_r);
]

let run_options : zi_opt_list = [
  (["-m"; "--main"],    i_ "name of the file to execute",           parse_m);
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
                 run_options @ update_options @ common_options;
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
  ("add", offline_options @ generic_select_options);
  ("select", offline_options @ select_options);
  ("show", xml_output @ show_options);
  ("download", offline_options @ download_options @ select_options);
  ("run", offline_options @ run_options @ generic_select_options);
  ("update", update_options @ offline_options @ generic_select_options);
  ("whatchanged", diff_options);
  ("destroy", []);
  ("config", []);
  ("import", offline_options);
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
  let (raw_options, args) = Support.Argparse.parse_args spec args in

  (* Default values *)
  let options = {
    config;
    gui = Maybe;
    dry_run = false;
    verbosity = 0;
    extra_options = [];
    network_use = Full_network;
    args;
  } in

  options.extra_options <- Support.Utils.filter_map raw_options ~f:(fun (opt, value) -> match value with
    | UseGUI b -> options.gui <- b; None
    | DryRun -> raise Fallback_to_Python
    | Verbose -> increase_verbosity options; None
    | WithStore store -> add_store options store; None
    | ShowVersion -> raise Fallback_to_Python
    | NetworkUse u -> options.network_use <- u; None
    | Help -> raise Fallback_to_Python
    | AmbiguousOption fn -> (match args with
        | command :: _ -> Some (opt, fn command)
        | _ -> raise_safe "Option '%s' requires a command" opt
    )
    | _ -> Some (opt, value)
  );

  (* This check is mainly to prevent command_options getting out-of-date *)
  let () = match args with
  | command :: _ -> check_options command options.extra_options
  | [] -> () in

  options
;;
