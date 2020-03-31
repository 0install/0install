(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Displays a few paragraphs of help text in a dialog box. *)

open Support.Common
open Gtk_common

let create title sections =
  object
    val mutable dialog = None

    method display =
      dialog |> if_some (fun box -> box#destroy ());
      let box = GWindow.dialog
        ~title
        ~position:`CENTER
        () in
      dialog <- Some box;

      box#action_area#set_border_width 4;

      let swin = GBin.scrolled_window
        ~hpolicy:`AUTOMATIC
        ~vpolicy:`ALWAYS
        ~shadow_type:`IN
        ~border_width:2
        () in

      box#vbox#pack (swin :> GObj.widget) ~expand:true ~fill:true;

      let text = GText.view
        ~wrap_mode:`WORD
        ~editable:false
        ~cursor_visible:false
        () in
      text#set_left_margin 4;
      text#set_right_margin 4;

      let model = text#buffer in
      let iter = model#start_iter in
      let heading_style = model#create_tag [`UNDERLINE `SINGLE; `SCALE `LARGE] in

      let first = ref true in
      sections |> List.iter (fun (heading, body) ->
        if !first then (
          first := false
        ) else (
          model#insert ~iter "\n\n";
        );
        model#insert ~iter ~tags:[heading_style] heading;
        model#insert ~iter ("\n" ^ body);
      );
      swin#add (text :> GObj.widget);

      box#add_button_stock `CLOSE `CLOSE;
      box#connect#response ==> (function
        | `CLOSE | `DELETE_EVENT -> box#destroy ()
      );
      box#connect#destroy ==> (fun () -> dialog <- None);
      box#set_default_response `CLOSE;
      box#set_default_size
        ~width:(Gdk.Screen.width () / 4)
        ~height:(Gdk.Screen.height () / 3);
      box#show ()
  end
