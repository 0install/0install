(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Handling --verbose, etc *)

open Zeroinstall.General
open Support.Common
open Options

let format_type = function
  | Dir -> "DIR"
  | ImplRelPath -> "PATH"
  | Command -> "COMMAND"
  | VersionRange -> "RANGE"
  | SimpleVersion -> "VERSION"
  | CpuType -> "CPU"
  | OsType -> "OS"
  | Message -> "STRING"
  | HashType -> "ALG"
  | IfaceURI -> "URI"

let add_store settings store =
  settings.config.extra_stores <- settings.config.extra_stores @ [store];
  settings.config.stores <- settings.config.stores @ [store];
  log_info "Stores search path is now %s" @@ String.concat path_sep settings.config.stores

let increase_verbosity options =
  options.verbosity <- options.verbosity + 1;
  let open Support.Logging in
  Printexc.record_backtrace true;
  if options.verbosity = 1 then (
    threshold := Info;
    (* Print this as soon as possible once logging is on *)
    log_info "OCaml front-end to 0install: verbose mode on"
  ) else (
    threshold := Debug
  )

let show_version system =
  system#print_string @@ Printf.sprintf
    "0install (zero-install) %s\n\
     Copyright (C) 2013 Thomas Leonard\n\
     This program comes with ABSOLUTELY NO WARRANTY,\n\
     to the extent permitted by law.\n\
     You may redistribute copies of this program\n\
     under the terms of the GNU Lesser General Public License.\n\
     For more information about these matters, see the file named COPYING.\n"
     Zeroinstall.About.version

let show_help valid_options help extra_fn =
  let open Format in
  open_vbox 0;

  printf "Usage: 0install %s@\n" help;

  extra_fn ();

  Support.Argparse.format_options format_type valid_options;

  close_box();
  print_newline()

let process_common_option options =
  let config = options.config in
  function
  | `UseGUI b -> options.gui <- b
  | `DryRun -> config.dry_run <- true; config.system <- new Zeroinstall.Dry_run.dryrun_system config.system
  | `Verbose -> increase_verbosity options
  | `WithStore store -> add_store options store
  | `ShowVersion -> show_version config.system; raise (System_exit 0)
  | `NetworkUse u -> config.network_use <- u
  | `Help -> raise (Support.Argparse.Usage_error 0)
