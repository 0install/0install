(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Common types for user interface callbacks *)

open General
open Support.Common

let string_of_ynm = function
  | Yes -> "yes"
  | No -> "no"
  | Maybe -> "maybe"

type key_vote_type = Good | Bad
type key_vote = (key_vote_type * string)

class type ui_handler =
  object
    (** A new download has been added (may still be queued).
     * @param cancel function to call to cancel the download
     * @param url the URL being downloaded (used in the console display)
     * @param progress a signal of (bytes-so-far, total-expected)
     * @param hint the feed associated with this download
     * @param size the expected size in bytes, if known
     * @param id a unique ID for this download *)
    method start_monitoring : cancel:(unit -> unit Lwt.t) -> url:string -> progress:(Int64.t * Int64.t option) Lwt_react.S.t ->
                              ?hint:string -> size:(Int64.t option) -> id:string -> unit Lwt.t

    (** A download has finished (successful or not) *)
    method stop_monitoring : filepath -> unit Lwt.t

    (** Ask the user to confirm they trust at least one of the signatures on this feed.
     * @param key_info a list of fingerprints and their (eventual) votes
     * Return the list of fingerprints the user wants to trust. *)
    method confirm_keys : [`remote_feed of General.feed_url] -> (Support.Gpg.fingerprint * key_vote list Lwt.t) list -> Support.Gpg.fingerprint list Lwt.t

    (** Display a confirmation request *)
    method confirm : string -> [`ok | `cancel] Lwt.t

    (* A bit hacky: should we use Gui for solve_and_download_impls? *)
    method use_gui : bool
  end

class python_ui (slave:Python.slave) =
  let downloads = Hashtbl.create 10 in

  let json_of_votes =
    List.map (function
      | Good, msg -> `List [`String "good"; `String msg]
      | Bad, msg -> `List [`String "bad"; `String msg]
    ) in

  let () =
    Python.register_handler "abort-download" (function
      | [`String id] ->
          begin try
            let cancel, _progress = Hashtbl.find downloads id in
            Lwt.bind (cancel ()) (fun () -> Lwt.return `Null)
          with Not_found ->
            log_info "abort-download: %s not found" id;
            Lwt.return `Null end
      | json -> raise_safe "download-archives: invalid request: %s" (Yojson.Basic.to_string (`List json))
    ) in

  object (_ : #ui_handler)
    method start_monitoring ~cancel ~url ~progress ?hint ~size ~id =
      let size =
        match size with
        | None -> `Null
        | Some size -> `Float (Int64.to_float size) in
      let hint =
        match hint with
        | None -> `Null
        | Some hint -> `String hint in
      let details = `Assoc [
        ("url", `String url);
        ("hint", hint);
        ("size", size);
        ("tempfile", `String id);
      ] in
      let updates = progress |> Lwt_react.S.map_s (fun (sofar, total) ->
        if Hashtbl.mem downloads id then (
          let sofar = Int64.to_float sofar in
          let total =
            match total with
            | None -> `Null
            | Some total -> `Float (Int64.to_float total) in
          slave#invoke_async (`List [`String "set-progress"; `String id; `Float sofar; total]) Python.expect_null
        ) else Lwt.return ()
      ) in
      Hashtbl.add downloads id (cancel, updates);     (* (store updates to prevent GC) *)
      slave#invoke_async (`List [`String "start-monitoring"; details]) Python.expect_null

    method stop_monitoring id =
      Hashtbl.remove downloads id;
      slave#invoke_async (`List [`String "stop-monitoring"; `String id]) Python.expect_null

    method confirm_keys feed_url infos =
      let pending_tasks = ref [] in

      let handle_pending fingerprint votes =
        let task =
          lwt votes = votes in
          let request = `List [`String "update-key-info"; `String fingerprint; `List (json_of_votes votes)] in
          slave#invoke_async request Python.expect_null in
        pending_tasks := task :: !pending_tasks in

      try_lwt
        let json_infos = infos |> List.map (fun (fingerprint, votes) ->
          let json_votes =
            match Lwt.state votes with
            | Lwt.Sleep -> handle_pending fingerprint votes; [`String "pending"]
            | Lwt.Fail ex -> [`List [`String "bad"; `String (Printexc.to_string ex)]]
            | Lwt.Return votes -> json_of_votes votes in
          (fingerprint, `List json_votes)
        ) in
        let request = `List [`String "confirm-keys"; `String (Feed_url.format_url feed_url); `Assoc json_infos] in
        slave#invoke_async request (function
          | `List confirmed_keys -> confirmed_keys |> List.map Yojson.Basic.Util.to_string
          | _ -> raise_safe "Invalid response"
        )
      finally
        !pending_tasks |> List.iter Lwt.cancel;
        Lwt.return ()

    method confirm message =
      let request = `List [`String "confirm"; `String message] in
      slave#invoke_async request (function
        | `String "ok" -> `ok
        | `String "cancel" -> `cancel
        | _ -> raise_safe "Invalid response"
      )

    method use_gui = false
  end

class console_ui slave =
  (* Interact with the user on stderr because we may be writing XML to stdout *)
  let print fmt =
    let do_print msg = prerr_string (msg ^ "\n"); flush stderr in
    Printf.ksprintf do_print fmt in

  object (self)
    inherit python_ui slave

    method! confirm message =
      prerr_endline message;
      let rec loop () =
        prerr_string "[Y/N] ";
        flush stderr;
        match trim (input_line stdin) with
        | "N" | "n" -> `cancel
        | "Y" | "y" -> `ok
        | _ -> loop () in
      loop () |> Lwt.return

    method! confirm_keys feed_url key_infos =
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
            | Good, msg -> print "- %s" msg
            | Bad, msg -> print "- BAD: %s" msg
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
  end

class batch_ui slave =
  object (_ : #ui_handler)
    inherit console_ui slave

    method! start_monitoring ~cancel:_ ~url:_ ~progress:_ ?hint:_ ~size:_ ~id:_ = Lwt.return ()
    method! stop_monitoring _id = Lwt.return ()

(* For now, for the unit-tests, fall back to Python.

    method confirm_keys _feed_url _xml =
      raise_safe "Can't confirm keys as in batch mode."

    method update_key_info _fingerprint _xml = assert false

    method confirm_distro_install _package_impls =
      raise_safe "Can't confirm installation of distribution packages as in batch mode."
*)
  end

class gui_ui slave =
  object
    inherit python_ui slave
    method! use_gui = true
  end

let check_gui (system:system) (slave:Python.slave) use_gui =
  if use_gui = No then false
  else (
    match system#getenv "DISPLAY" with
    | None | Some "" ->
        if use_gui = Maybe then false
        else raise_safe "Can't use GUI because $DISPLAY is not set"
    | Some _ ->
        slave#invoke_async (`List [`String "check-gui"; `String (string_of_ynm use_gui)]) Yojson.Basic.Util.to_bool |> Lwt_main.run
  )

let make_ui config (slave:Python.slave) get_use_gui : ui_handler Lazy.t = lazy (
  let use_gui =
    match get_use_gui (), config.dry_run with
    | Yes, true -> raise_safe "Can't use GUI with --dry-run"
    | (Maybe|No), true -> No
    | use_gui, false -> use_gui in

  let make_no_gui () =
    if config.system#isatty Unix.stderr then
      new console_ui slave
    else
      new batch_ui slave in

  match use_gui with
  | No -> make_no_gui ()
  | Yes | Maybe ->
      if check_gui config.system slave use_gui then new gui_ui slave
      else make_no_gui ()   (* [check-gui] will throw if use_gui is [Yes] *)
)
