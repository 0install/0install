(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

type t = GTree.list_store
type iter = Gtk.tree_iter

let list_store cols = GTree.list_store cols
let clear (model:t) = model#clear ()
let model_sort model = GTree.model_sort model
let get_iter_first (model:t) = model#get_iter_first
let set (model:t) ~(row:iter) ~column value = model#set ~row ~column value
let get (model:t) ~(row:iter) ~column = model#get ~row ~column
let remove (model:t) (row:iter) = model#remove row
let convert_iter_to_child_iter (model:GTree.model_sort) (iter:Gtk.tree_iter) = model#convert_iter_to_child_iter iter
let append (model:t) = model#append ()
let iter_next (model:t) (row:iter) = model#iter_next row
