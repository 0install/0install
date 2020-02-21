(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** To be opened by all GTK modules. *)

(** Connect a signal handler, ignoring the resulting signal ID.
 * This avoids having to use [|> ignore] everywhere. *)
let (==>) (signal:(callback:_ -> GtkSignal.id)) callback =
  ignore (signal ~callback)

(** Create a widget and ignore it. This is useful for decorations (e.g. labels)
 * to avoid using the generic [ignore], which can ignore other things too. *)
let ignore_widget : #GObj.widget -> unit = ignore

(** Append a column and ignore the returned column ID. *)
let append_column (tv:GTree.view) (col:GTree.view_column) =
  ignore (tv#append_column col)

(** Append a notebook page and ignore the returned page number. *)
let append_page (nb:GPack.notebook) ?tab_label page =
  ignore (nb#append_page ?tab_label page)

let with_insensitive (widget:#GObj.widget) f =
  widget#misc#set_sensitive false;
  Lwt.finalize f
    (fun () -> widget#misc#set_sensitive true; Lwt.return ())
