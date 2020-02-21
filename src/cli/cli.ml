(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Parsing command-line arguments *)

open Options
open Zeroinstall.General
open Support
open Support.Common
open Support.Argparse

let starts_with = XString.starts_with

let i_ x = x

class ['a, 'b] ambiguous_no_arg (actual:'a) reader =
  object (_ : ('a, 'b) #option_parser)
    method get_reader = reader
    method parse = function
      | [] -> actual
      | _ -> Safe_exn.failf "Option takes no arguments in this context"
  end

class ['a, 'b] ambiguous_one_arg (actual:'a) (reader:'b option_reader) =
  object (_ : (_, _) #option_parser)
    method get_reader = reader
    method parse = function
      | [x] -> actual x
      | _ -> Safe_exn.failf "Option takes one argument in this context"
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
  ([      "--command"],     1, i_ "command to select",                 new one_arg CommandName @@ fun c -> `SelectCommand c);
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
  (["-w"; "--wrapper"], 1, i_ "execute program using a debugger, etc", new one_arg CommandName @@ fun cmd -> `Wrapper cmd);
]

let common_options : (_, _) opt_spec list = [
  (["-c"; "--console"],    0, i_ "never use GUI",                     new no_arg @@ `UseGUI `No);
  ([      "--dry-run"],    0, i_ "just print what would be executed", new no_arg @@ `DryRun);
  (["-g"; "--gui"],        0, i_ "show graphical policy editor",      new no_arg @@ `UseGUI `Yes);
  (["-h"; "--help"],       0, i_ "show this help message and exit",   new no_arg @@ `Help);
  (["-v"; "--verbose"],    0, i_ "more verbose output",               new no_arg @@ `Verbose);
  ([      "--with-store"], 1, i_ "add an implementation cache",       new one_arg Dir @@ fun path -> `WithStore path);
]

let show_version_options : (_, _) opt_spec list = [
  (["-V"; "--version"],    0, i_ "display version information",       new ambiguous_no_arg `ShowVersion read_version_option);
]

let may_compile_options : (_, _) opt_spec list = [
  (["--may-compile"],    0, i_ "consider potential binaries too",     new no_arg @@ `MayCompile);
]

let spec : (_, zi_arg_type) argparse_spec = {
  options_spec = generic_select_options @ offline_options @ digest_options @
                 xml_output @ diff_options @ download_options @ show_options @
                 run_options @ show_version_options @ common_options @ may_compile_options;
  no_more_options = function
    | [_; "run"] | [_; "runenv"] -> true
    | _ -> false;
}

let select_options = xml_output @ generic_select_options

open Command_tree

let store_commands : commands = [
  "add",      make_command "DIGEST (DIRECTORY | (ARCHIVE [EXTRACT]))"   Store.handle_add @@ common_options;
  "audit",    make_command "[DIRECTORY]"                                Store.handle_audit @@ common_options;
  "copy",     make_command "SOURCE [ TARGET ]"                          Store.handle_copy @@ common_options;
  "find",     make_command "DIGEST"                                     Store.handle_find @@ common_options;
  "list",     make_command ""                                           Store.handle_list @@ common_options;
  "manifest", make_command "DIRECTORY [ALGORITHM]"                      Store.handle_manifest @@ common_options;
  "optimise", make_command "[ CACHE ]"                                  Optimise.handle     @@ common_options;
  "verify",   make_command "(DIGEST | (DIRECTORY [DIGEST])"             Store.handle_verify @@ common_options;
  "manage",   make_command ""                                           Manage_cache.handle @@ common_options;
]

(** Which options are valid with which command *)
let commands : commands = [
  "add",          make_command "PET-NAME INTERFACE"            Add.handle        @@ common_options @ offline_options @ generic_select_options;
  "select",       make_command "URI"                           Select.handle     @@ common_options @ offline_options @ select_options @ may_compile_options;
  "show",         make_command "APP | SELECTIONS"              Show.handle       @@ common_options @ xml_output @ show_options;
  "download",     make_command "URI"                           Download.handle   @@ common_options @ offline_options @ download_options @ select_options;
  "run",          make_command "URI [ARGS]"                    Run.handle        @@ common_options @ offline_options @ run_options @ generic_select_options;
  "update",       make_command "APP | URI"                     Update.handle     @@ common_options @ offline_options @ generic_select_options;
  "_update-bg",   make_command_hidden                          Update.handle_bg  @@ common_options;
  "whatchanged",  make_command "APP-NAME"                      Whatchanged.handle @@ common_options @ diff_options;
  "destroy",      make_command "PET-NAME"                      Destroy.handle    @@ common_options;
  "config",       make_command "[NAME [VALUE]]"                Conf.handle       @@ common_options;
  "import",       make_command "FEED"                          Import.handle     @@ common_options @ offline_options;
  "list",         make_command "PATTERN"                       List_ifaces.handle @@ common_options;
  "search",       make_command "QUERY"                         Search.handle     @@ common_options;
  "add-feed",     make_command "[INTERFACE] NEW-FEED"          Add_feed.handle   @@ common_options @ offline_options;
  "remove-feed",  make_command "[INTERFACE] FEED"              Remove_feed.handle @@ common_options @ offline_options;
  "list-feeds",   make_command "URI"                           List_feeds.handle @@ common_options;
  "man",          make_command "NAME"                          Man.handle        @@ common_options;
  "digest",       make_command "DIRECTORY | ARCHIVE [EXTRACT]" Store.handle_digest @@ common_options @ digest_options;
  "_desktop",     make_command_hidden                          Desktop.handle    @@ common_options;
  "_alias",       make_command_hidden                          Alias.handle      @@ common_options;
  "store",        make_group   store_commands;
  "slave",        make_command "VERSION"                       Slave.handle      @@ common_options;
]

let pp_commands parents fmt commands =
  commands |> List.iter (fun (command, info) ->
    match info with
    | Command info when (Command_tree.help info = None) -> ()
    | _ -> Format.fprintf fmt "0install%s %s@," parents command
  )

let show_group_help config parents f group =
  let top_options = show_version_options @ common_options in
  Common_options.show_help config.system top_options "COMMAND [OPTIONS]" f (fun fmt ->
    let parents = String.concat "" (List.map ((^) " ") parents) in
    Format.fprintf fmt "Try --help with one of these:@\n@\n@[<v2>  %a@]@."
      (pp_commands parents) group
  )

let handle_no_command options flags args =
  assert (args = []);
  let exit_status = ref 1 in
  Support.Argparse.iter_options flags (function
    | `Help -> exit_status := 0
    | #common_option as o -> Common_options.process_common_option options o
  );
  show_group_help options.config [] options.stdout commands;
  raise (System_exit !exit_status)

let no_command = (make_command_hidden handle_no_command @@ common_options @ show_version_options)

let make_tools config =
  let gui = ref `Auto in
  let pool = ref None in
  let ui = lazy (Zeroinstall.Default_ui.make_ui config ~use_gui:!gui) in
  let packagekit = lazy (Zeroinstall.Packagekit.make (Support.Locale.LangMap.choose config.langs |> fst)) in
  let distro = lazy (Zeroinstall.Distro_impls.get_host_distribution ~packagekit config) in
  let trust_db = lazy (new Zeroinstall.Trust.trust_db config) in
  let download_pool = lazy (let p = Zeroinstall.Downloader.make_pool ~max_downloads_per_site:2 in pool := Some p; p) in
  let make_fetcher = lazy (Zeroinstall.Fetch.make config (Lazy.force trust_db) (Lazy.force distro) (Lazy.force download_pool)) in
  object (_ : Options.tools)
    method config = config
    method ui = Lazy.force ui
    method distro = Lazy.force distro
    method download_pool = Lazy.force download_pool
    method set_use_gui value = gui := value
    method make_fetcher watcher = (Lazy.force make_fetcher) watcher
    method trust_db = Lazy.force trust_db
    method use_gui = !gui
    method release = !pool |> if_some (fun pool -> pool#release)
  end

let get_default_options ~stdout config =
  let options = {
    config;
    stdout;
    verbosity = 0;
    tools = make_tools config;
  } in
  options

let release_options options =
  options.tools#release

let handle ~stdout config raw_args =
  let (raw_options, args, complete) = read_args spec raw_args in
  assert (complete = CompleteNothing);

  Support.Utils.finally_do release_options
    (get_default_options ~stdout config)
    (fun options ->
      let command_path, subcommand, command_args =
        match args with
        | [] -> ([], no_command, [])
        | ["run"] when List.mem ("-V", []) raw_options -> (["run"], no_command, [])      (* Hack for 0launch -V *)
        | command_args -> lookup (make_group commands) command_args in
      match subcommand with
      | Group subgroup ->
          show_group_help config command_path options.stdout subgroup;
          raise (System_exit 1)
      | Command subcommand ->
          try Command_tree.handle subcommand options raw_options command_path command_args
          with ShowVersion -> Common_options.show_version options.stdout config.system
    )
