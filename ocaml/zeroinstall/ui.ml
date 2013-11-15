(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Common types for user interface callbacks *)

open General
open Support.Common

module U = Support.Utils

external get_terminal_width : unit -> int = "ocaml_0install_get_terminal_width"

let string_of_ynm = function
  | Yes -> "yes"
  | No -> "no"
  | Maybe -> "maybe"

type key_vote_type = Good | Bad
type key_vote = (key_vote_type * string)

class type ui_handler =
  object
    method start_monitoring : cancel:(unit -> unit Lwt.t) -> url:string -> progress:(Int64.t * Int64.t option) Lwt_react.S.t ->
                              ?hint:string -> id:string -> unit Lwt.t
    method stop_monitoring : filepath -> unit Lwt.t
    method confirm_keys : [`remote_feed of General.feed_url] -> (Support.Gpg.fingerprint * key_vote list Lwt.t) list -> Support.Gpg.fingerprint list Lwt.t
    method confirm : string -> [`ok | `cancel] Lwt.t
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
    method start_monitoring ~cancel ~url ~progress ?hint ~id =
      let size =
        match snd @@ Lwt_react.S.value progress with
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

class console_ui =
  let downloads = Hashtbl.create 10 in
  let disable_progress = ref 0 in     (* [> 0] when we're asking the user a question *)
  let display_thread = ref None in
  let last_updated = ref "" in
  let msg = ref "" in

  let clear () =
    if !msg <> "" then (
      for i = 0 to String.length !msg - 1 do !msg.[i] <- ' ' done;
      prerr_string @@ "\r" ^ !msg ^ "\r";
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

  (* Select the most interesting download in [downloads] and return its ID. *)
  let find_most_progress () =
    let find_best id (_url, _cancel, progress) =
      let (sofar, _) as progress = Lwt_react.S.value progress in
      function
      | Some (_best_id, (best_sofar, _)) as prev_best when Int64.compare sofar best_sofar < 0 -> prev_best
      | _ -> Some (id, progress) in
    Hashtbl.fold find_best downloads None |> pipe_some (fun (id, _) -> Some id) in

  (* Interact with the user on stderr because we may be writing XML to stdout *)
  let print fmt =
    let do_print msg = prerr_string (msg ^ "\n"); flush stderr in
    Printf.ksprintf do_print fmt in

  let run_display_thread () =
    let next_switch_time = ref 0. in
    let current_favourite = ref "" in
    let rec loop () =
      let n_downloads = Hashtbl.length downloads in
      if !disable_progress > 0 || n_downloads = 0 then ()
      else (
        let now = Unix.time () in
        let best =
          if now < !next_switch_time && Hashtbl.mem downloads !current_favourite then Some (!current_favourite)
          else if Hashtbl.mem downloads !last_updated then Some (!last_updated)
          else find_most_progress () in
        match best with
        | None -> clear ()
        | Some best ->
            if best <> !current_favourite then (
              current_favourite := best;
              next_switch_time := now +. 1.0;
            );
            let (url, _cancel, progress) = Hashtbl.find downloads best in
            let (sofar, total) = Lwt_react.S.value progress in
            let progress_str =
              match total with
              | None -> Printf.sprintf "%6s / unknown" (Int64.to_string sofar)  (* (could be bytes or percent) *)
              | Some total -> Printf.sprintf "%s / %s" (Int64.to_string sofar) (U.format_size total) in
            clear ();
            Support.Logging.clear_fn := Some clear;
            if n_downloads = 1 then
              msg := Printf.sprintf "[one download] %16s (%s)" progress_str url
            else
              msg := Printf.sprintf "[%d downloads] %16s (%s)" n_downloads progress_str url;
            let max_width = get_terminal_width () in
            if max_width > 0 && String.length !msg > max_width then msg := String.sub !msg 0 max_width;
            prerr_string !msg;
            flush stderr
      );
      lwt () = Lwt_unix.sleep 0.1 in
      loop () in
    loop () in

  object (self : #ui_handler)
    method start_monitoring ~cancel ~url ~progress ?hint:_  ~id =
      let progress = progress |> React.S.map (fun v -> last_updated := id; v) in
      Hashtbl.add downloads id (url, cancel, progress);     (* (store updates to prevent GC) *)

      if !display_thread = None then (
        display_thread := Some (run_display_thread ())
      );

      Lwt.return ()

    method stop_monitoring id =
      Hashtbl.remove downloads id;
      begin match Hashtbl.length downloads, !display_thread with
      | 0, Some thread ->
          Lwt.cancel thread;
          clear ();
          display_thread := None
      | _ -> () end;
      Lwt.return ()

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
      )

    method use_gui = false
  end

class batch_ui =
  object (_ : #ui_handler)
    inherit console_ui

    method! start_monitoring ~cancel:_ ~url:_ ~progress:_ ?hint:_ ~id:_ = Lwt.return ()
    method! stop_monitoring _id = Lwt.return ()

(* For now, for the unit-tests, fall back to Python.
    method! confirm_keys _feed _infos =
      raise_safe "Can't confirm keys as in batch mode."

    method! confirm message =
      raise_safe "Can't confirm in batch mode (%s)" message
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
      new console_ui
    else
      new batch_ui in

  match use_gui with
  | No -> make_no_gui ()
  | Yes | Maybe ->
      if check_gui config.system slave use_gui then new gui_ui slave
      else make_no_gui ()   (* [check-gui] will throw if use_gui is [Yes] *)
)
