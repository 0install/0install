(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Keeps track of download progress. *)

open Support
open Support.Common
open Gtk_common

module Downloader = Zeroinstall.Downloader

type t = {
  solver_box : Solver_box.solver_box Lwt.t;
  mutable n_completed_downloads : int;
  mutable size_completed_downloads : int64;
  mutable downloads : Downloader.download list;
}

let rec monitor_downloads t =
  match t.downloads with
  | [] -> Lwt.return ()
  | dls ->
    Lwt_unix.sleep 0.2 >>= fun () ->
    t.downloads <- dls |> List.filter (fun dl ->
        if Downloader.is_in_progress dl then true
        else (
          log_debug "stop_monitoring %s" dl.Downloader.url;
          let (bytes, _, _) = Lwt_react.S.value dl.Downloader.progress in
          t.n_completed_downloads <- t.n_completed_downloads + 1;
          t.size_completed_downloads <- Int64.add t.size_completed_downloads bytes;
          false
        )
      );
    t.solver_box >>= fun box ->
    box#update_download_status
      ~n_completed_downloads:t.n_completed_downloads
      ~size_completed_downloads:t.size_completed_downloads
      t.downloads;
    monitor_downloads t

let make_watcher solver_box tools ~trust_db reqs =
  let feed_provider = ref (new Zeroinstall.Feed_provider_impl.feed_provider tools#config tools#distro) in
  let original_solve = Zeroinstall.Solver.solve_for tools#config !feed_provider reqs in
  let original_selections =
    match original_solve with
    | (false, _) -> None
    | (true, results) -> Some (Zeroinstall.Solver.selections results) in
  let t = { n_completed_downloads = 0; size_completed_downloads = 0L; downloads = []; solver_box } in

  object (_ : #Zeroinstall.Progress.watcher)
    val mutable pulse = None
    val mutable results = original_solve

    method feed_provider = !feed_provider
    method results = results
    method original_selections = original_selections

    method update (new_results, new_fp) =
      feed_provider := new_fp;
      results <- new_results;

      Gtk_utils.async (fun () ->
        solver_box >|= fun box ->
        box#update
      )

    method report feed_url msg =
      let e = Safe_exn.v "Feed '%s': %s" (Zeroinstall.Feed_url.format_url feed_url) msg in
      Gtk_utils.async (fun () ->
        solver_box >|= fun box ->
        box#report_error e
      )

    method monitor dl =
      log_debug "start_monitoring %s" dl.Downloader.url;
      t.downloads <- dl :: t.downloads;
      if pulse = None then (
        pulse <- Some (
            Lwt.finalize
              (fun () -> with_errors_logged (fun f -> f "GUI update failed") (fun () -> monitor_downloads t))
              (fun () ->
                 pulse <- None;
                 (* We do this here, rather than in [stop_monitoring], to introduce a delay,
                  * since we often start a new download immediately after another one finished and
                  * we don't want to reset in that case. *)
                 t.n_completed_downloads <- 0;
                 t.size_completed_downloads <- 0L;
                 Lwt.return ()
              )
          )
      )

    method impl_added_to_store =
      Gtk_utils.async (fun () ->
        solver_box >|= fun box ->
        box#impl_added_to_store
      )

    method confirm_keys feed_url infos =
      solver_box >>= fun box ->
      box#ensure_main_window >>= fun parent ->
      let open Zeroinstall.General in
      let gpg = Support.Gpg.make tools#config.system in
      Trust_box.confirm_keys ~parent gpg trust_db feed_url infos

    method confirm message =
      solver_box >>= fun box ->
      box#ensure_main_window >>= fun parent ->
      let box = GWindow.message_dialog
        ~parent
        ~message_type:`QUESTION
        ~title:"Confirm"
        ~message
        ~buttons:GWindow.Buttons.ok_cancel
        () in
      let result, set_result = Lwt.wait () in
      box#set_default_response `OK;
      box#connect#response ==> (fun response ->
        box#destroy ();
        Lwt.wakeup set_result (
          match response with
          | `OK -> `Ok
          | `CANCEL | `DELETE_EVENT -> `Cancel
        )
      );
      box#show ();
      result

    method abort_all_downloads =
      t.downloads |> List.iter (fun dl ->
        Gtk_utils.async dl.Downloader.cancel
      )
  end
