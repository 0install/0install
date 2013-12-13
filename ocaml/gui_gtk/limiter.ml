(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Queuing of GUI updates. *)

open Support.Common

let () = ignore on_windows

(** When [run fn] is called, run it asynchronously. If called again while it's still running, queue the next run.
 * If called while something is queued, drop the queued item and queue the new one instead.
 * This is useful to ensure that updates to the GUI are displayed, but don't interfere with each other. *)
let make_limiter ~parent () =
  let state = ref `idle in
  let rec run fn =
    match !state with
    | `running | `running_with_queued _  -> state := `running_with_queued fn
    | `idle ->
        state := `running;
        Gtk_utils.async ~parent (fun () ->
          try_lwt
            fn ()
          finally
            begin match !state with
            | `idle -> assert false
            | `running -> state := `idle
            | `running_with_queued fn -> state := `idle; run fn end;
            Lwt.return ()
        ) in
  run
