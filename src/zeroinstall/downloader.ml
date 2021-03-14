(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Low-level download interface *)

open Support
open Support.Common

module U = Support.Utils

type progress = (Int64.t * Int64.t option * bool) Lwt_react.signal

type download = {
  cancel : unit -> unit Lwt.t;
  url : string;
  progress : progress;    (* Must keep a reference to this; if it gets GC'd then updates stop. *)
  hint : string option;
}

type download_result =
 [ `Aborted_by_user
 | `Network_failure of string
 | `Tmpfile of Support.Common.filepath ]

let is_in_progress dl =
  let (_, _, finished) = Lwt_react.S.value dl.progress in
  not finished

let interceptor = ref None        (* (for unit-tests) *)

module Site = struct
  type t = {
    max_downloads_per_site : int;
    connections : Http.Connection.t option ref Queue.t;
    pool : Http.Connection.t option ref Lwt_pool.t;
  }

  (** Rate-limits downloads within a site.
   * [domain] is e.g. "http://site:port" - the URL before the path *)
  let make ~max_downloads_per_site =
    let connections = Queue.create () in
    let create_connection () =
      let connection = Http.Connection.create () in
      let r = ref (Some connection) in
      Queue.add r connections;
      Lwt.return r in
    let validate c = Lwt.return (!c <> None) in
    let pool = Lwt_pool.create max_downloads_per_site create_connection ~validate in
    {
      max_downloads_per_site;
      connections;
      pool;
    }

  let schedule_download t ~cancelled ?if_slow ?size ?modification_time ?start_offset ~progress ch url =
    log_debug "Scheduling download of %s" url;
    if XString.starts_with url "https://downloads.sourceforge.net/#!" then
      Lwt.return (`Network_failure "SourceForge is currently in Disaster Recovery mode (unusable)")
    else if not (List.exists (XString.starts_with url) ["http://"; "https://"; "ftp://"]) then (
      Safe_exn.failf "Invalid scheme in URL '%s'" url
    ) else (
      Lwt_pool.use t.pool (fun r ->
          match !r with
          | None -> failwith "Attempt to use a freed connection!"
          | Some connection ->
            match !interceptor with
            | Some interceptor ->
              interceptor ?if_slow ?size ?modification_time ch url
            | None ->
              let timeout = if_slow |> pipe_some (fun if_slow ->
                  let timeout = Lwt_timeout.create 5 (fun () -> Lazy.force if_slow) in
                  Lwt_timeout.start timeout;
                  Some timeout;
                ) in
              let download () = Http.Connection.get ~cancelled ?modification_time ?size ?start_offset ~progress connection ch url in
              Lwt.finalize download
                (fun () ->
                   timeout |> if_some Lwt_timeout.stop;
                   Lwt.return ()
                )
        )
    )

  (** Clean up all connections. Call this before discarding the site. *)
  let release t =
    let cleanup r =
      match !r with
      | None -> log_warning "Attempt to cleanup an already-cleaned connection!"
      | Some c -> Http.Connection.release c; r := None in
    Queue.iter cleanup t.connections;
    Queue.clear t.connections
end

type monitor = download -> unit

type t = {
  monitor : monitor;
  sites : (string, Site.t) Hashtbl.t;
  max_downloads_per_site : int;
}

(** Empty the file and reset the FD to the start.
 * On Windows, we have to close and reopen the file to do this. *)
let truncate_to_empty tmpfile ch =
  flush !ch;
  if Sys.os_type = "Win32" then (
    close_out !ch;
    ch := open_out_gen [Open_wronly; Open_trunc; Open_binary] 0o700 tmpfile;
    Unix.set_close_on_exec (Unix.descr_of_out_channel !ch);
  ) else (
    Unix.ftruncate (Unix.descr_of_out_channel !ch) 0;
    seek_out !ch 0
  )

(** A temporary file that will be deleted when the switch is turned off. *)
let tmpfile_with_switch ~switch ~prefix ~suffix =
  let tmpfile, ch = Filename.open_temp_file ~mode:[Open_binary] prefix suffix in
  Unix.set_close_on_exec (Unix.descr_of_out_channel ch);
  let ch = ref ch in
  Lwt_switch.add_hook (Some switch) (fun () ->
    begin try
      close_out !ch;         (* For Windows: ensure file is closed before unlinking *)
      Unix.unlink tmpfile
    with ex ->
      log_warning ~ex "Failed to delete temporary file for download '%s'" tmpfile
    end;
    Lwt.return ()
  );
  tmpfile, ch

let get_site t domain =
  try Hashtbl.find t.sites domain
  with Not_found ->
    let site = Site.make ~max_downloads_per_site:t.max_downloads_per_site in
    Hashtbl.add t.sites domain site;
    site

let network_failure fmt =
  fmt |> Format.kasprintf @@ fun msg -> Lwt.return (`Network_failure msg)

let catch_cancel task =
  Lwt.catch (fun () -> task)
    (function
      | Lwt.Canceled -> Lwt.return `Aborted_by_user
      | ex -> Lwt.fail ex
    )

let download_if_unmodified t ~switch ?modification_time ?if_slow ?size ?start_offset ?hint url =
  let hint = hint |> pipe_some (fun feed -> Some (Feed_url.format_url feed)) in
  log_debug "Download URL '%s'... (for %s)" url (default "no feed" hint);
  let progress, set_progress = Lwt_react.S.create (Int64.zero, size, false) in
  let cancelled = ref false in
  let tmpfile, ch = tmpfile_with_switch ~switch ~prefix:"0install-" ~suffix:"-download" in
  let rec loop redirs_left url =
    let domain, _ = Support.Urlparse.split_path url in
    let site = get_site t domain in
    Site.schedule_download site ~cancelled ?if_slow ?size ?modification_time ?start_offset ~progress:set_progress !ch url >>= function
    | `Success ->
        close_out !ch;
        `Tmpfile tmpfile |> Lwt.return
    | (`Network_failure _ | `Aborted_by_user | `Unmodified) as result ->
        close_out !ch;
        Lwt.return result
    | `Redirect target ->
        truncate_to_empty tmpfile ch;
        if target = url then network_failure "Redirection loop getting '%s'" url
        else if redirs_left > 0 then loop (redirs_left - 1) target
        else network_failure "Too many redirections (next: %s)" target in
  (* Cancelling:
   * ocurl is missing OPENSOCKETFUNCTION, but we can get close by setting a flag so that it
   * aborts on the next write. In any case, we don't wait for the thread exit, as it may be
   * blocked on a DNS lookup, etc. *)
  let task, waker = Lwt.task () in
  let cancel () =
    log_info "Cancelling download %s" url;
    cancelled := true;
    Lwt.cancel task;
    Lwt.return () in
  let task = catch_cancel task in
  t.monitor {cancel; url; progress; hint};
  (* Do the download *)
  U.async (fun () ->
    Lwt.catch
      (fun () -> loop 10 url >|= Lwt.wakeup waker)
      (fun ex ->
         log_info ~ex "Download failed";
         close_out !ch;
         Lwt.wakeup_exn waker ex; Lwt.return ()
      )
  );
  (* Stop progress indicator when done *)
  Lwt.finalize
    (fun () -> task)
    (fun () ->
      let (sofar, total, _) = Lwt_react.S.value progress in
      set_progress (sofar, total, true);
      Lwt.return ()
    )

let download t ~switch ?if_slow ?size ?start_offset ?hint url =
  download_if_unmodified t ~switch ?if_slow ?size ?start_offset ?hint url >|= function
  | `Unmodified -> failwith "BUG: got Unmodified, but no expected modification time provided!"
  | #download_result as x -> x

class type download_pool =
  object
    method with_monitor : monitor -> t
    method release : unit
  end

let make_pool ~max_downloads_per_site : download_pool =
  let sites = Hashtbl.create 10 in

  object
    method with_monitor monitor = { monitor; sites; max_downloads_per_site }

    method release =
      Hashtbl.iter (fun _ -> Site.release) sites;
      Hashtbl.clear sites
  end
