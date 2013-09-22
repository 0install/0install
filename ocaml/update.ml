(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install update" command *)

open Zeroinstall.General
open Options
open Support.Common

module FeedAttr = Zeroinstall.Constants.FeedAttr
module Apps = Zeroinstall.Apps
module R = Zeroinstall.Requirements
module Q = Support.Qdom
module F = Zeroinstall.Feed

let get_root_sel sels =
  let iface = ZI.get_attribute FeedAttr.interface sels in
  let is_root sel = ZI.get_attribute FeedAttr.interface sel = iface in
  match Q.find is_root sels with
  | Some sel -> sel
  | None -> raise_safe "Can't find a selection for the root (%s)!" iface

let get_newest options feed_provider reqs =
  let module I = Zeroinstall.Impl_provider in
  let (scope_filter, _root_key) = Zeroinstall.Solver.get_root_requirements options.config reqs in
  let impl_provider = new I.default_impl_provider options.config feed_provider scope_filter in
  let get_impls = impl_provider#get_implementations reqs.R.interface_uri in

  let best = ref None in
  let check_best items =
    ListLabels.iter items ~f:(fun impl ->
      match !best with
      | None -> best := Some impl
      | Some old_best when F.(impl.parsed_version > old_best.parsed_version) -> best := Some impl
      | Some _ -> ()
    ) in

  let candidates = get_impls ~source:reqs.R.source in
  check_best candidates.I.impls;
  check_best @@ List.map fst candidates.I.rejects;
  if not reqs.R.source then (
    (* Also report newer source versions *)
    let candidates = get_impls ~source:true in
    check_best candidates.I.impls;
    check_best @@ List.map fst candidates.I.rejects
  );
  !best

let check_replacement system = function
  | None -> ()
  | Some (feed, _) ->
      match feed.F.replacement with
      | None -> ()
      | Some replacement ->
          Support.Utils.print system "Warning: interface %s has been replaced by %s" feed.F.url replacement

let check_for_updates options reqs old_sels =
  let driver = Lazy.force options.driver in
  let new_sels = Zeroinstall.Helpers.solve_and_download_impls driver
                          reqs `Download_only ~refresh:true ~use_gui:options.gui in
  match new_sels with
  | None -> raise (System_exit 1)   (* Aborted by user *)
  | Some new_sels ->
      let config = options.config in
      let system = config.system in
      let print fmt = Support.Utils.print system fmt in
      let feed_provider = new Zeroinstall.Feed_cache.feed_provider options.config driver#distro in
      check_replacement system @@ feed_provider#get_feed reqs.R.interface_uri;
      let root_sel = get_root_sel new_sels in
      let root_version = ZI.get_attribute FeedAttr.version root_sel in
      let changes = ref (Whatchanged.show_changes system old_sels new_sels) in
      if not !changes && Q.compare_nodes old_sels new_sels ~ignore_whitespace:true <> 0 then (
        changes := true;
        print "Updates to metadata found, but no change to version (%s)." root_version;
        log_debug "Old:\n%s\nNew:\n%s" (Q.to_utf8 old_sels) (Q.to_utf8 new_sels)
      );

      let () =
        match get_newest options feed_provider reqs with
        | None -> log_warning "Can't find any implementations! (BUG)"
        | Some best ->
            if best.F.parsed_version > Zeroinstall.Versions.parse_version root_version then (
              print "A later version (%s %s) exists but was not selected. Using %s instead."
                reqs.R.interface_uri (Zeroinstall.Versions.format_version best.F.parsed_version) root_version;
              if not config.help_with_testing && best.F.stability < Stable then
                print "To select \"testing\" versions, use:\n0install config help_with_testing True"
            ) else if not !changes then (
              print "No updates found. Continuing with version %s." root_version
            ) in

      if !changes then
        Some new_sels
      else
        None

let handle options flags args =
  let config = options.config in

  let select_opts = ref [] in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
    | #select_option as o -> select_opts := o :: !select_opts
    | `Refresh -> log_warning "deprecated: update implies --refresh anyway"
  );
  match args with
  | [arg] -> (
    let module G = Generic_select in
    match G.resolve_target config !select_opts arg with
    | (G.App (app, _old_reqs), reqs) ->
        let old_sels = Apps.get_selections_no_updates config.system app in
        let () =
          match check_for_updates options reqs old_sels with
          | Some new_sels -> Apps.set_selections config app new_sels ~touch_last_checked:true;
          | None -> () in
        Apps.set_requirements config app reqs
    | (G.Selections old_sels, reqs) -> ignore @@ check_for_updates options reqs old_sels
    | (G.Interface, reqs) ->
        (* Select once without downloading to get the old values *)
        let driver = Lazy.force options.driver in
        let feed_provider = new Zeroinstall.Feed_cache.feed_provider config driver#distro in
        let (ready, result) = Zeroinstall.Solver.solve_for config feed_provider reqs in
        let old_sels = result#get_selections in
        if not ready then old_sels.Q.child_nodes <- [];
        ignore @@ check_for_updates options reqs old_sels
  )
  | _ -> raise (Support.Argparse.Usage_error 1)

(** update-bg is a hidden command used internally to spawn background updates.
    stdout will be /dev/null. stderr will be too, unless using -vv. *)
let handle_bg options flags args =
  let config = options.config in
  let driver = Lazy.force options.driver in
  let slave = options.slave in

  let notify ~msg ~timeout =
    let fields = `Assoc [
      ("title", `String "0install");
      ("message", `String msg);
      ("timeout", `Int timeout);
    ] in
    slave#invoke (`List [`String "notify-user"; fields]) ignore in

  let need_confirm_keys = ref false in
  Zeroinstall.Python.read_user_input := (fun _prompt ->
    need_confirm_keys := true;
    raise_safe "need to switch to GUI to confirm keys"
  );

  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );

  match args with
    | ["app"; app] ->
        let name = Filename.basename app in
        let reqs = Apps.get_requirements config.system app in
        let old_sels = Apps.get_selections_no_updates config.system app in
        let check_offline = function
          | `String "offline" ->
              log_info "Background update: offline, so aborting";
              raise (System_exit 1)
          | _ -> () in
        options.slave#invoke (`List [`String "wait-for-network"]) check_offline;

        (* Refresh the feeds and solve, silently. If we find updates to download, we try to run the GUI
         * so the user can see a systray icon for the download. If that's not possible, we download silently too. *)
        let (ready, result, feed_provider) = driver#solve_with_downloads reqs ~force:true ~update_local:true in
        let new_sels = result#get_selections in

        let new_sels =
          let distro = driver#distro in
          if !need_confirm_keys || not ready || Zeroinstall.Selections.get_unavailable_selections config ~distro new_sels <> [] then (
            log_info "Background update: trying to use GUI to update %s" name;
            match Zeroinstall.Gui.get_selections_gui driver `Download_only reqs ~systray:true ~refresh:true ~use_gui:Maybe with
            | `Aborted_by_user -> raise (System_exit 0)
            | `Dont_use_GUI when !need_confirm_keys ->
                let msg = Printf.sprintf "Can't update 0install app '%s' without user intervention (run '0install update %s' to fix)" name name in
                notify ~timeout:10 ~msg;
                log_warning "%s" msg;
                raise (System_exit 1)
            | `Dont_use_GUI when not ready ->
                let msg = Printf.sprintf "Can't update 0install app '%s' (run '0install update %s' to fix)" name name in
                notify ~timeout:10 ~msg;
                log_warning "Update of 0install app %s failed: %s" name (Zeroinstall.Diagnostics.get_failure_reason config result);
                raise (System_exit 1)
            | `Dont_use_GUI ->
                log_info "Background update: GUI unavailable; downloading with no UI";
                Zeroinstall.Helpers.download_selections ~include_packages:true ~feed_provider driver new_sels; new_sels
            | `Success gui_sels -> gui_sels
          ) else new_sels in

        if Q.compare_nodes old_sels new_sels ~ignore_whitespace:true <> 0 then (
          Apps.set_selections config app new_sels ~touch_last_checked:true;
          let msg = Printf.sprintf "%s updated" name in
          log_info "Background update: %s" msg;
          notify ~msg ~timeout:1;
        ) else (
          log_info "Background update: no updates found for %s" name;
          Apps.set_last_checked config.system app
        )
    | _ -> raise (Support.Argparse.Usage_error 1)

