(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Queuing of GUI updates. *)

(** When [run fn] is called, run it asynchronously. If called again while it's still running, queue the next run.
 * If called while something is queued, drop the queued item and queue the new one instead.
 * This is useful to ensure that updates to the GUI are displayed, but don't interfere with each other. *)
let make_limiter ~parent =
  let state = ref `Idle in
  let rec run fn =
    match !state with
    | `Running | `Running_with_queued _  -> state := `Running_with_queued fn
    | `Idle ->
        state := `Running;
        Gtk_utils.async ~parent (fun () ->
          Lwt.finalize fn
            (fun () ->
              begin match !state with
              | `Idle -> assert false
              | `Running -> state := `Idle
              | `Running_with_queued fn -> state := `Idle; run fn end;
              Lwt.return ()
            )
        ) in
  run
