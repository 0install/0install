(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** High-level helper functions *)

(** Create a UI appropriate for the current environment and user options.
 * This will be a graphical UI if [Gui.try_get_gui] returns one and we're not in dry-run mode.
 * Otherwise, it will be an interactive console UI if stderr is a tty.
 * Otherwise, it will be a batch UI (no progress display).
 *)
val make_ui :
  General.config ->
  use_gui:[< `Yes | `No | `Auto] ->
  Ui.ui_handler
