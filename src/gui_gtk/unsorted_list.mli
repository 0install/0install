(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A GTK list store with its own types *)

(* When displaying items in a TreeView/IconView, we often have two models: an
 * underlying model and a sorted view of it, which is what the widget displays.
 * It's very important not to confuse the iterators of one model with those of
 * the other, or you may act on the wrong data.
 *
 * For example, to delete a row you need to call the delete operation on the underlying model,
 * using an underlying iterator. But the TreeView's get_selected_rows returns iterators in the
 * sorted model.
 *
 * This module isolates the underlying model and its iterators from the rest of the code, so
 * mixups aren't possible.
 *)
type t
type iter
val list_store : GTree.column_list -> t
val clear : t -> unit
val model_sort : t -> GTree.model_sort
val get_iter_first : t -> iter option
val set : t -> row:iter -> column:'a GTree.column -> 'a -> unit
val get : t -> row:iter -> column:'a GTree.column -> 'a
val remove : t -> iter -> bool
val convert_iter_to_child_iter : GTree.model_sort -> Gtk.tree_iter -> iter
val append : t -> iter
val iter_next : t -> iter -> bool
