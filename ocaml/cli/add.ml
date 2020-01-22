(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install add" command *)

open Options
open Support
open Support.Common

module Apps = Zeroinstall.Apps
module U = Support.Utils
module R = Zeroinstall.Requirements
module F = Zeroinstall.Feed

(** Warn the user if [uri] has been replaced. *)
let check_for_replacement f config uri =
  let feed = Zeroinstall.Feed_url.master_feed_of_iface uri in
  match Zeroinstall.Feed_cache.get_cached_feed config feed with
  | None -> log_warning "Master feed for '%s' missing!" uri
  | Some feed ->
      match F.replacement feed with
      | Some replacement ->
        Format.fprintf f "Warning: interface %s has been replaced by %s@." uri replacement
      | None -> ()

let handle options flags args =
  let select_opts = ref [] in
  let refresh = ref false in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
    | #binary_select_option as o -> select_opts := o :: !select_opts
    | `Refresh -> refresh := true
  );
  match args with
  | [pet_name; arg] -> (
      let module G = Generic_select in
      match G.resolve_target options.config !select_opts arg with
      | (G.Interface, reqs) -> (
          match G.get_selections options ~refresh:!refresh reqs `Download_only |> Lwt_main.run with
          | `Aborted_by_user -> raise (System_exit 1)
          | `Success sels ->
              check_for_replacement options.stdout options.config reqs.R.interface_uri;
              let app = Apps.create_app options.config pet_name reqs in
              Apps.set_selections options.config app sels ~touch_last_checked:true;
              Apps.integrate_shell options.config app pet_name
      )
      | (G.Selections _, _) -> Safe_exn.failf "'%s' is a selections document, not an interface URI" arg
      | (G.App _, _) -> Safe_exn.failf "'%s' is an app, not an interface URI" arg
  )
  | _ -> raise (Support.Argparse.Usage_error 1)
