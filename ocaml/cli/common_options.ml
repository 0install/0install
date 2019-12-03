(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Handling --verbose, etc *)

open Zeroinstall.General
open Support
open Support.Common
open Options

exception Retry_with_dryrun
(** --dry-run flag found and not in dry-run mode (triggers a restart in dry-run mode) *)

let format_type = function
  | Dir -> "DIR"
  | ImplRelPath -> "PATH"
  | CommandName -> "COMMAND"
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
  let module L = Support.Logging in
  Printexc.record_backtrace true;
  if options.verbosity = 1 then (
    L.threshold := L.Info;
    (* Print this as soon as possible once logging is on *)
    log_info "0install %s (OCaml version): verbose mode on" Zeroinstall.About.version
  ) else (
    L.threshold := L.Debug
  )

let show_version f system =
  let prog = Filename.basename system#argv.(0) in
  let prog = if XString.starts_with prog "0launch" then "0launch" else "0install" in
  Format.fprintf f
    "%s (zero-install) %s@,\
     Copyright (C) 2019 Thomas Leonard@\n\
     This program comes with ABSOLUTELY NO WARRANTY,@ \
     to the extent permitted by law.@ \
     You may redistribute copies of this program@ \
     under the terms of the GNU Lesser General Public License.@ \
     For more information about these matters, see the file named COPYING.@.\
     Compiled with D-Bus support: %b@.\
     HTTP client library: %s@."
     prog Zeroinstall.About.version
     Zeroinstall.Dbus.have_dbus
     Zeroinstall.Http.variant

let show_help (system:system) valid_options help f extra_fn =
  let prog = Filename.basename system#argv.(0) in
  let usage =
    if XString.starts_with prog "0launch" then "[OPTIONS] URI [ARGS]"
    else if XString.starts_with prog "0desktop" then "[OPTIONS] [URI]"
    else help in
  Format.fprintf f "Usage: %s %s@.@\n%t%a@."
    prog usage extra_fn
    (Support.Argparse.pp_options format_type) valid_options

let process_common_option options =
  let config = options.config in
  function
  | `UseGUI b -> options.tools#set_use_gui b
  | `DryRun -> if not config.dry_run then raise Retry_with_dryrun
  | `Verbose -> increase_verbosity options
  | `WithStore store -> add_store options store
  | `ShowVersion -> show_version options.stdout config.system; raise (System_exit 0)
  | `NetworkUse u -> config.network_use <- u
  | `Help -> raise (Support.Argparse.Usage_error 0)
