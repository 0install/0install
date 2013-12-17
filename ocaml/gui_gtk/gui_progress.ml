(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Keeps track of download progress. *)

open Support.Common

module Downloader = Zeroinstall.Downloader

let make_watcher solver_box tools ~trust_db reqs =
  let feed_provider = ref (new Zeroinstall.Feed_provider_impl.feed_provider tools#config tools#distro) in
  let original_solve = Zeroinstall.Solver.solve_for tools#config !feed_provider reqs in
  let original_selections =
    match original_solve with
    | (false, _) -> StringMap.empty
    | (true, results) -> Zeroinstall.Selections.make_selection_map results#get_selections in

  object (_ : #Zeroinstall.Progress.watcher)
    val mutable n_completed_downloads = 0
    val mutable size_completed_downloads = 0L
    val mutable downloads = []
    val mutable pulse = None

    val mutable results = original_solve

    method feed_provider = !feed_provider
    method results = results
    method original_selections = original_selections

    method update (new_results, new_fp) =
      feed_provider := new_fp;
      results <- new_results;

      Gtk_utils.async (fun () ->
        lwt box = solver_box in
        box#update;
        Lwt.return ()
      )

    method report feed_url msg =
      let msg = Printf.sprintf "Feed '%s': %s" (Zeroinstall.Feed_url.format_url feed_url) msg in
      Gtk_utils.async (fun () ->
        lwt box = solver_box in
        box#report_error (Safe_exception (msg, ref []));
        Lwt.return ()
      )

    method monitor dl =
      log_debug "start_monitoring %s" dl.Downloader.url;
      downloads <- dl :: downloads;

      if pulse = None then (
        pulse <- Some (
          try_lwt
            while_lwt downloads <> [] do
              lwt () = Lwt_unix.sleep 0.2 in
              downloads <- downloads |> List.filter (fun dl ->
                if Downloader.is_in_progress dl then true
                else (
                  log_debug "stop_monitoring %s" dl.Downloader.url;
                  let (bytes, _, _) = Lwt_react.S.value dl.Downloader.progress in
                  n_completed_downloads <- n_completed_downloads + 1;
                  size_completed_downloads <- Int64.add size_completed_downloads bytes;
                  false
                )
              );
              lwt box = solver_box in
              box#update_download_status ~n_completed_downloads ~size_completed_downloads downloads;
              Lwt.return ()
            done
          with ex ->
            log_warning ~ex "GUI update failed";
            Lwt.return ()
          finally
            pulse <- None;
            (* We do this here, rather than in [stop_monitoring], to introduce a delay,
             * since we often start a new download immediately after another one finished and
             * we don't want to reset in that case. *)
            n_completed_downloads <- 0;
            size_completed_downloads <- 0L;
            Lwt.return ()
        )
      )

    method impl_added_to_store =
      Gtk_utils.async (fun () ->
        lwt box = solver_box in
        box#impl_added_to_store;
        Lwt.return ()
      )

    method confirm_keys feed_url infos =
      lwt box = solver_box in
      lwt parent = box#ensure_main_window in
      Trust_box.confirm_keys ~parent tools#config trust_db feed_url infos

    method confirm message =
      lwt box = solver_box in
      lwt parent = box#ensure_main_window in

      let box = GWindow.message_dialog
        ~parent
        ~message_type:`QUESTION
        ~title:"Confirm"
        ~message
        ~buttons:GWindow.Buttons.ok_cancel
        () in
      let result, set_result = Lwt.wait () in
      box#set_default_response `OK;
      box#connect#response ~callback:(fun response ->
        box#destroy ();
        Lwt.wakeup set_result (
          match response with
          | `OK -> `ok
          | `CANCEL | `DELETE_EVENT -> `cancel
        )
      ) |> ignore;
      box#show ();
      result

    method abort_all_downloads =
      downloads |> List.iter (fun dl ->
        Gtk_utils.async dl.Downloader.cancel
      )
  end
