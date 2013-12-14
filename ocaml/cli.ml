(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing command-line arguments *)

open Options
open Zeroinstall.General
open Support.Common
open Support.Argparse

let starts_with = Support.Utils.starts_with

let i_ x = x

class ['a, 'b] ambiguous_no_arg (actual:'a) reader =
  object (_ : ('a, 'b) #option_parser)
    method get_reader = reader
    method parse = function
      | [] -> actual
      | _ -> raise_safe "Option takes no arguments in this context"
  end

class ['a, 'b] ambiguous_one_arg (actual:'a) (reader:'b option_reader) =
  object (_ : (_, _) #option_parser)
    method get_reader = reader
    method parse = function
      | [x] -> actual x
      | _ -> raise_safe "Option takes one argument in this context"
  end

exception ShowVersion

class ['a, 'b] ambiguous_version_arg (reader:'b option_reader) =
  object (_ : ('a, _) #option_parser)
    method get_reader = reader
    method parse = function
      | [x] -> `RequireVersion x
      | _ -> raise ShowVersion
  end

(* This is tricky, because --version does two things:
   [0install --version] shows the version of 0install.
   [0install --version=1 run foo] runs version 1 of "foo". *)
let read_version_option =
  object
    method read _opt_name _command stream ~completion:_ =
      match Stream.peek stream with
      | None -> []                                (* --version *)
      | Some next when starts_with next "-" -> [] (* --version --verbose *)
      | Some next -> Stream.junk stream; [next]   (* --version 1 *)

    method get_arg_types = function
      | 0 -> []
      | 1 -> [VersionRange]
      | _ -> assert false
  end

(* -m might or might not take an argument. Very tricky! *)
let read_m =
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

    method get_arg_types = function
      | 0 -> []
      | 1 -> [ImplRelPath]
      | _ -> assert false
  end

let parse_version_for =
  object
    inherit [_, zi_arg_type] two_arg IfaceURI VersionRange (fun u v -> `RequireVersionFor(u, v)) as super

    method! get_reader =
      object
        method get_arg_types = super#get_reader#get_arg_types
        method read opt_name command stream ~completion =
          let as_super () = super#get_reader#read opt_name command stream ~completion in
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
  end

let generic_select_options : (_, _) opt_spec list = [
  ([      "--before"],      0, i_ "choose a version before this",      new one_arg SimpleVersion @@ fun v -> `Before v);
  ([      "--command"],     1, i_ "command to select",                 new one_arg Command @@ fun c -> `SelectCommand c);
  ([      "--cpu"],         1, i_ "target CPU type",                   new one_arg CpuType @@ fun c -> `Cpu c);
  ([      "--message"],     1, i_ "message to display when interacting with user", new one_arg Message @@ fun m -> `WithMessage m);
  ([      "--not-before"],  1, i_ "minimum version to choose",         new one_arg SimpleVersion @@ fun v -> `NotBefore v);
  ([      "--os"],          1, i_ "target operation system type",      new one_arg OsType @@ fun o -> `Os o);
  (["-r"; "--refresh"],     0, i_ "refresh all used interfaces",       new ambiguous_no_arg `Refresh no_arg_reader);
  (["-s"; "--source"],      0, i_ "select source code",                new no_arg @@ `Source);
  ([      "--version"],     1, i_ "specify version constraint (e.g. '3' or '3..')", new ambiguous_version_arg read_version_option);
  ([      "--version-for"], 2, i_ "set version constraints for a specific interface", parse_version_for);
]

let offline_options = [
  (["-o"; "--offline"],     0, i_ "try to avoid using the network",    new no_arg @@ `NetworkUse Offline);
]

let digest_options = [
  ([      "--algorithm"], 1, i_ "the hash function to use", new one_arg HashType @@ fun h -> `UseHash h);
  (["-m"; "--manifest"],  0, i_ "print the manifest",       new ambiguous_no_arg `ShowManifest read_m);
  (["-d"; "--digest"],    0, i_ "print the digest",         new no_arg `ShowDigest);
]

let xml_output = [
  (["--xml"], 0, i_ "print selections as XML", new no_arg `ShowXML);
]

let diff_options = [
  (["--full"], 0, i_ "show diff of the XML", new no_arg `ShowFullDiff);
]

let download_options = [
  (["--show"], 0, i_ "show where components are installed", new no_arg `ShowHuman);
]

let show_options = [
  (["-r"; "--root-uri"], 0, i_ "display just the root interface URI", new ambiguous_no_arg `ShowRoot no_arg_reader);
]

let run_options : (_, _) opt_spec list = [
  (["-m"; "--main"],    1, i_ "name of the file to execute",           new ambiguous_one_arg (fun m -> `MainExecutable m) read_m);
  (["-w"; "--wrapper"], 1, i_ "execute program using a debugger, etc", new one_arg Command @@ fun cmd -> `Wrapper cmd);
]

let common_options : (_, _) opt_spec list = [
  (["-c"; "--console"],    0, i_ "never use GUI",                     new no_arg @@ `UseGUI No);
  ([      "--dry-run"],    0, i_ "just print what would be executed", new no_arg @@ `DryRun);
  (["-g"; "--gui"],        0, i_ "show graphical policy editor",      new no_arg @@ `UseGUI Yes);
  (["-h"; "--help"],       0, i_ "show this help message and exit",   new no_arg @@ `Help);
  (["-v"; "--verbose"],    0, i_ "more verbose output",               new no_arg @@ `Verbose);
  ([      "--with-store"], 1, i_ "add an implementation cache",       new one_arg Dir @@ fun path -> `WithStore path);
]

let show_version_options : (_, _) opt_spec list = [
  (["-V"; "--version"],    0, i_ "display version information",       new ambiguous_no_arg `ShowVersion read_version_option);
]

let spec : (_, zi_arg_type) argparse_spec = {
  options_spec = generic_select_options @ offline_options @ digest_options @
                 xml_output @ diff_options @ download_options @ show_options @
                 run_options @ show_version_options @ common_options;
  no_more_options = function
    | [_; "run"] | [_; "runenv"] -> true
    | _ -> false;
}

let select_options = xml_output @ generic_select_options

let make_command_obj help handler valid_options =
  object
    method handle options raw_options command_path args =
      let flags = parse_options valid_options raw_options in
      try handler options flags args
      with Support.Argparse.Usage_error status ->
        let command = String.concat " " command_path in
        Common_options.show_help options.config.system valid_options (command ^ " [OPTIONS] " ^ help) ignore;
        raise (System_exit status)

    method options = (valid_options :> (zi_option, _) opt_spec list)
    method help = help
  end

type subcommand =
   < handle : global_settings -> raw_option list -> string list -> string list -> unit;
     help : string;
     options : (Options.zi_option, Options.zi_arg_type) Support.Argparse.opt_spec list >
and subgroup = (string * subnode) list
and subnode =
  | Subcommand of subcommand
  | Subgroup of subgroup

let make_subcommand name help handler valid_options =
  (name, Subcommand (make_command_obj help handler valid_options))

let make_subgroup name subcommands =
  (name, Subgroup subcommands)

let store_subcommands : subgroup = [
  make_subcommand "add"       "DIGEST (DIRECTORY | (ARCHIVE [EXTRACT]))"   Store.handle_add @@ common_options;
  make_subcommand "audit"     "[DIRECTORY]"                                Store.handle_audit @@ common_options;
  make_subcommand "copy"      "SOURCE [ TARGET ]"                          Store.handle_copy @@ common_options;
  make_subcommand "find"      "DIGEST"                                     Store.handle_find @@ common_options;
  make_subcommand "list"      ""                                           Store.handle_list @@ common_options;
  make_subcommand "manifest"  "DIRECTORY [ALGORITHM]"                      Store.handle_manifest @@ common_options;
  make_subcommand "optimise"  "[ CACHE ]"                                  Optimise.handle     @@ common_options;
  make_subcommand "verify"    "(DIGEST | (DIRECTORY [DIGEST])"             Store.handle_verify @@ common_options;
  make_subcommand "manage"    ""                                           Manage_cache.handle @@ common_options;
]

(** Which options are valid with which command *)
let subcommands: subgroup = [
  make_subcommand "add"         "PET-NAME INTERFACE"            Add.handle        @@ common_options @ offline_options @ generic_select_options;
  make_subcommand "select"      "URI"                           Select.handle     @@ common_options @ offline_options @ select_options;
  make_subcommand "show"        "APP | SELECTIONS"              Show.handle       @@ common_options @ xml_output @ show_options;
  make_subcommand "download"    "URI"                           Download.handle   @@ common_options @ offline_options @ download_options @ select_options;
  make_subcommand "run"         "URI [ARGS]"                    Run.handle        @@ common_options @ offline_options @ run_options @ generic_select_options;
  make_subcommand "update"      "APP | URI"                     Update.handle     @@ common_options @ offline_options @ generic_select_options;
  make_subcommand "update-bg"   "-"                             Update.handle_bg  @@ common_options;
  make_subcommand "whatchanged" "APP-NAME"                      Whatchanged.handle @@ common_options @ diff_options;
  make_subcommand "destroy"     "PET-NAME"                      Destroy.handle    @@ common_options;
  make_subcommand "config"      "[NAME [VALUE]]"                Conf.handle       @@ common_options;
  make_subcommand "import"      "FEED"                          Import.handle     @@ common_options @ offline_options;
  make_subcommand "list"        "PATTERN"                       List_ifaces.handle @@ common_options;
  make_subcommand "search"      "QUERY"                         Search.handle     @@ common_options;
  make_subcommand "add-feed"    "[INTERFACE] NEW-FEED"          Add_feed.handle   @@ common_options @ offline_options;
  make_subcommand "remove-feed" "[INTERFACE] FEED"              Remove_feed.handle @@ common_options @ offline_options;
  make_subcommand "list-feeds"  "URI"                           List_feeds.handle @@ common_options;
  make_subcommand "man"         "NAME"                          Man.handle        @@ common_options;
  make_subcommand "digest"      "DIRECTORY | ARCHIVE [EXTRACT]" Store.handle_digest @@ common_options @ digest_options;
  make_subcommand "_desktop"    "-"                             Desktop.handle    @@ common_options;
  make_subgroup   "store"       store_subcommands;
  make_subcommand "slave"       "VERSION"                       Slave.handle      @@ common_options;
]

let show_group_help config parents group =
  let print fmt = Support.Utils.print config.system fmt in
  let top_options = show_version_options @ common_options in
  Common_options.show_help config.system top_options "COMMAND [OPTIONS]" (fun () ->
    let parents = String.concat "" (List.map ((^) " ") parents) in
    print "\nTry --help with one of these:\n";
    ListLabels.iter group ~f:(fun (command, info) ->
      match info with
      | Subcommand info when info#help = "-" -> ()
      | _ -> print "0install%s %s" parents command;
    );
  )

let handle_no_command options flags args =
  assert (args = []);
  Support.Argparse.iter_options flags (function
    | `Help -> ()
    | #common_option as o -> Common_options.process_common_option options o
  );
  show_group_help options.config [] subcommands;
  raise (System_exit 1)

let no_command = make_command_obj "" handle_no_command @@ common_options @ show_version_options

let rec set_of_option_names = function
  | Subcommand command ->
      let add s (names, _nargs, _help, _handler) = List.fold_right StringSet.add names s in
      List.fold_left add StringSet.empty command#options
  | Subgroup group ->
      group |> List.fold_left (fun set (_name, node) -> StringSet.union set (set_of_option_names node)) StringSet.empty

let make_tools config =
  let gui = ref Maybe in
  let ui = lazy (Zeroinstall.Helpers.make_ui config !gui) in
  let distro = lazy (Zeroinstall.Distro_impls.get_host_distribution config) in
  let trust_db = lazy (new Zeroinstall.Trust.trust_db config) in
  let download_pool = lazy (Zeroinstall.Downloader.make_pool ~max_downloads_per_site:2) in
  let make_fetcher = lazy (new Zeroinstall.Fetch.fetcher config (Lazy.force trust_db) (Lazy.force distro) (Lazy.force download_pool)) in
  object (_ : Options.tools)
    method config = config
    method ui = Lazy.force ui
    method distro = Lazy.force distro
    method download_pool = Lazy.force download_pool
    method set_use_gui value = gui := value
    method make_fetcher watcher = (Lazy.force make_fetcher) watcher
    method trust_db = Lazy.force trust_db
    method use_gui = !gui
  end

let get_default_options config =
  let options = {
    config;
    verbosity = 0;
    tools = make_tools config;
  } in
  options

let rec lookup_subcommand config name args (group:subgroup) : (string list * subcommand * string list) =
  let subcommand =
    try List.assoc name group
    with Not_found -> raise_safe "Unknown 0install sub-command '%s': try --help" name in
  match subcommand with
  | Subcommand subcommand -> ([name], subcommand, args)
  | Subgroup subgroup ->
      match args with
      | subname :: subargs ->
          let (path, command, args) = lookup_subcommand config subname subargs subgroup in
          (name :: path, command, args)
      | [] ->
          show_group_help config [name] subgroup;
          raise (System_exit 1)

let handle config raw_args =
  let (raw_options, args, complete) = read_args spec raw_args in
  assert (complete = CompleteNothing);

  Support.Utils.finally_do (fun _options -> Zeroinstall.Python.cancel_slave () |> Lwt_main.run)
    (get_default_options config)
    (fun options ->
      let command_path, subcommand, command_args =
        match args with
        | [] -> ([], no_command, [])
        | ["run"] when List.mem ("-V", []) raw_options -> (["run"], no_command, [])      (* Hack for 0launch -V *)
        | command :: command_args -> lookup_subcommand config command command_args subcommands in
      try subcommand#handle options raw_options command_path command_args
      with ShowVersion -> Common_options.show_version config.system
    )
