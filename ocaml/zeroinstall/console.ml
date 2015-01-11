(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Common types for user interface callbacks *)

open Support.Common

module U = Support.Utils

external get_terminal_width : unit -> int = "ocaml_0install_get_terminal_width"

let is_in_progress = function
  | None -> false
  | Some dl -> Downloader.is_in_progress dl

class console_ui =
  let downloads : Downloader.download list ref = ref [] in
  let disable_progress = ref 0 in     (* [> 0] when we're asking the user a question *)
  let display_thread = ref None in
  let last_updated = ref None in
  let msg = ref "" in

  let clear () =
    if !msg <> "" then (
      let blank = String.make (String.length !msg) ' ' in
      Printf.fprintf stderr "\r%s\r" blank;
      flush stderr;
      msg := "";
      Support.Logging.clear_fn := None
    ) in

  let with_disabled_progress fn =
    clear ();
    incr disable_progress;
    try_lwt fn ()
    finally
      disable_progress := !disable_progress - 1;
      Lwt.return () in

  (* Select the most interesting download in [downloads] and return its ID.
   * Also, removes any finished downloads from the list. *)
  let find_most_progress () =
    let old_downloads = !downloads in
    downloads := [];
    let best = ref None in
    old_downloads |> List.iter (fun dl ->
      if Downloader.is_in_progress dl then (
        downloads := dl :: !downloads;
        let (current_sofar, _, _) = Lwt_react.S.value dl.Downloader.progress in
        match !best with
        | Some (best_sofar, _best_dl) when Int64.compare current_sofar best_sofar < 0 -> ()
        | _ -> best := Some (current_sofar, dl)
      )
    );
    !best |> pipe_some (fun x -> Some (snd x)) in

  (* Interact with the user on stderr because we may be writing XML to stdout *)
  let print fmt =
    let do_print msg = prerr_string (msg ^ "\n"); flush stderr in
    Printf.ksprintf do_print fmt in

  let run_display_thread () =
    try_lwt
      let next_switch_time = ref 0. in
      let current_favourite = ref None in
      let rec loop () =
        let now = Unix.time () in
        let best =
          if !disable_progress > 0 then None
          else if now < !next_switch_time && is_in_progress !current_favourite then !current_favourite
          else if is_in_progress !last_updated then !last_updated
          else find_most_progress () in
        begin match best with
        | None -> clear ()
        | Some dl as best ->
            let n_downloads = List.length !downloads in
            if best != !current_favourite then (
              current_favourite := best;
              next_switch_time := now +. 1.0;
            );
            let (sofar, total, _finished) = Lwt_react.S.value dl.Downloader.progress in
            let progress_str =
              match total with
              | None -> Printf.sprintf "%6s / unknown" (Int64.to_string sofar)  (* (could be bytes or percent) *)
              | Some total -> Printf.sprintf "%s / %s" (Int64.to_string sofar) (U.format_size total) in
            clear ();
            Support.Logging.clear_fn := Some clear;
            if n_downloads = 1 then
              msg := Printf.sprintf "[one download] %16s (%s)" progress_str dl.Downloader.url
            else
              msg := Printf.sprintf "[%d downloads] %16s (%s)" n_downloads progress_str dl.Downloader.url;
            let max_width = get_terminal_width () in
            if max_width > 0 && String.length !msg > max_width then msg := String.sub !msg 0 max_width;
            prerr_string !msg;
            flush stderr end;
        lwt () = Lwt_unix.sleep 0.1 in
        loop () in
      loop ()
    with ex ->
      log_warning ~ex "Progress thread error";
      Lwt.return () in

  object (self : #Ui.ui_handler as 'a)
    constraint 'a = #Progress.watcher

    method run_solver tools ?test_callback ?systray mode reqs ~refresh =
      try_lwt
        let config = tools#config in
        ignore test_callback;
        ignore systray;
        let fetcher = tools#make_fetcher (self :> Progress.watcher) in
        lwt result = Driver.solve_with_downloads config tools#distro fetcher reqs ~watcher:self ~force:refresh ~update_local:refresh in
        match result with
        | (false, result, _) -> raise_safe "%s" (Solver.get_failure_reason config result)
        | (true, result, feed_provider) ->
            let sels = Solver.selections result in
            match mode with
            | `Select_only -> Lwt.return (`Success sels)
            | `Download_only | `Select_for_run ->
                match_lwt Driver.download_selections config tools#distro (lazy fetcher) ~feed_provider ~include_packages:true sels with
                | `success -> Lwt.return (`Success sels)
                | `aborted_by_user -> Lwt.return `Aborted_by_user
      finally
        if find_most_progress () = None then clear ();
        Lwt.return ()

    method update _ = ()

    method report feed_url msg =
      log_warning "Feed %s: %s" (Feed_url.format_url feed_url) msg

    method monitor dl =
      (* log_debug "Start monitoring %s" dl.Downloader.url; *)
      let progress =
        dl.Downloader.progress
        |> React.S.map (fun v ->
          last_updated := Some dl;
          if (not (Downloader.is_in_progress dl) && List.length !downloads = 1) then (
            clear ();     (* The last download has finished - clear the display immediately. *)
          );
          v) in
      let dl = {dl with Downloader.progress} in     (* (store updates to prevent GC) *)
      downloads := dl :: !downloads;

      if !display_thread = None then (
        display_thread := Some (run_display_thread ())
      )

    method confirm message =
      with_disabled_progress (fun () ->
        prerr_endline message;
        let rec loop () =
          prerr_string "[Y/N] ";
          flush stderr;
          match trim (input_line stdin) with
          | "N" | "n" -> `cancel
          | "Y" | "y" -> `ok
          | _ -> loop () in
        loop () |> Lwt.return
      )

    method confirm_keys feed_url key_infos =
      with_disabled_progress (fun () ->
        print "Feed: %s" (Feed_url.format_url feed_url);

        print "The feed is correctly signed with the following keys:";
        key_infos |> List.iter (fun (fingerprint, _) ->
          print "- %s" fingerprint
        );

        (* Print the key info as it arrives, until we have all of it or the user presses a key *)
        let have_multiple_keys = List.length key_infos > 1 in
        let shown = ref false in
        let printers = key_infos |> Lwt_list.iter_p (fun (fingerprint, votes) ->
          try_lwt
            lwt votes = votes in
            if have_multiple_keys then print "%s:" fingerprint;
            votes |> List.iter (function
              | Progress.Good, msg -> print "- %s" msg
              | Progress.Bad, msg -> print "- BAD: %s" msg
            );
            if List.length votes > 0 then shown := true;
            Lwt.return ()
          with ex ->
            log_warning ~ex "Failed to get key info";
            Lwt.return ()
        ) in

        lwt () =
          (* Only wait for a key if something is pending. This is useful for the unit-tests. *)
          if Lwt.state printers = Lwt.Sleep then (
            let user_interrupt =
              lwt _ = Lwt_io.read_char Lwt_io.stdin in
              print "Skipping remaining key lookups due to input from user";
              Lwt.return () in
            Lwt.pick [user_interrupt; printers]
          ) else Lwt.return () in

        if not !shown then print "Warning: Nothing known about this key!";

        let domain = Trust.domain_from_url feed_url in
        let prompt =
          if have_multiple_keys then
            Printf.sprintf "Do you want to trust all of these keys to sign feeds from '%s'?" domain
          else
            Printf.sprintf "Do you want to trust this key to sign feeds from '%s'?" domain in

        match_lwt self#confirm prompt with
        | `ok -> key_infos |> List.map fst |> Lwt.return
        | `cancel -> Lwt.return []
      )

    method impl_added_to_store = ()

    method watcher = (self :> Progress.watcher)

    method show_preferences = None
    method open_app_list_box = raise_safe "Not available without a GUI (hint: try with --gui)"
    method open_add_box = raise_safe "Not available without a GUI (hint: try with --gui)"
    method open_cache_explorer = raise_safe "Not available without a GUI (hint: try with --gui)"
  end

class batch_ui =
  object
    inherit console_ui

    method! monitor _dl = ()

(* For now, for the unit-tests, fall back to Python.
    method! confirm_keys _feed _infos =
      raise_safe "Can't confirm keys as in batch mode."

    method! confirm message =
      raise_safe "Can't confirm in batch mode (%s)" message
*)
  end
