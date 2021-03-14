(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Displays a form to the user to collect extra information for the bug report. *)

open Support.Common
open Gtk_common

module U = Support.Utils

let spf = Printf.sprintf

let frame ~packing ~title =
  let frame = GBin.frame ~packing ~shadow_type:`NONE () in
  let label = GMisc.label
    ~markup:(Printf.sprintf "<b>%s</b>" title)
    () in
  frame#set_label_widget (Some (label :> GObj.widget));

  let align = GBin.alignment ~packing:frame#add ~xalign:0.0 ~yalign:0.0 ~xscale:1.0 ~yscale:1.0 () in
  align#set_left_padding 16;
  align

let text_area ?(mono=false) ?(text="") ~packing () =
  let swin = GBin.scrolled_window
    ~packing
    ~hpolicy:`AUTOMATIC
    ~vpolicy:`ALWAYS
    ~shadow_type:`IN
    () in

  let tv = GText.view ~packing:swin#add ~wrap_mode:`WORD ~accepts_tab:false () in
  tv#buffer#insert text;

  if mono then
    tv#misc#modify_font (GPango.font_description_from_string "mono");

  tv#buffer

let create ?run_test ?last_error ~role ~results config =
  (* Collect information about system *)
  let details = Zeroinstall.Gui.get_bug_report_details config ~role results in

  (* Create dialog box *)
  let box = GWindow.dialog
    ~title:"Report a Bug"
    ~position:`CENTER
    () in

  box#action_area#set_border_width 4;

  let vbox = GPack.vbox ~packing:(box#vbox#pack ~expand:true) ~border_width:10 ~spacing:4 () in
  let packing = vbox#pack ~expand:true in

  let whats_broken =
    let f = frame ~packing ~title:"What doesn't work?" in
    text_area ~packing:f#add () in

  let expected =
    let f = frame ~packing ~title:"What did you expect to happen?" in
    text_area ~packing:f#add () in

  let any_errors =
    let f = frame ~packing ~title:"Are any errors or warnings displayed?" in
    let errors_box = GPack.vbox ~packing:f#add () in
    let buttons = GPack.button_box `HORIZONTAL ~packing:(errors_box#pack ~padding:4) ~layout:`START () in
    let get_errors = GButton.button ~packing:buttons#pack ~label:"Run it now and record the output" () in

    let buffer = text_area ~mono:true ~packing:(errors_box#pack ~expand:true) () in

    last_error |> if_some (fun ex -> Printexc.to_string ex |> buffer#insert);

    begin match run_test with
    | Some run_test ->
        get_errors#connect#clicked ==> (fun () ->
          get_errors#misc#set_sensitive false;
          Gtk_utils.async ~parent:box (fun () ->
            Lwt.finalize
              (fun () -> run_test () >|= buffer#insert ~iter:buffer#end_iter)
              (fun () ->
                get_errors#misc#set_sensitive true;
                Lwt.return ()
              )
          )
        );
    | None -> get_errors#misc#set_sensitive false end;
    buffer in

  let about_system =
    let f = frame ~packing ~title:"Information about your setup" in
    text_area ~text:details ~mono:true ~packing:f#add () in

  box#add_button_stock `CANCEL `CANCEL;
  box#add_button_stock `OK `OK;
  box#set_default_response `OK;

  box#connect#response ==> (function
    | `CANCEL | `DELETE_EVENT -> box#destroy ()
    | `OK ->
        let message = spf "\
          What doesn't work?\n\n\
          %s\n\n\
          What did you expect to happen?\n\n\
          %s\n\n\
          Are any errors or warnings displayed?\n\n\
          %s\n\n\
          Information about your setup\n\n\
          %s\n"
          (whats_broken#get_text ())
          (expected#get_text ())
          (any_errors#get_text ())
          (about_system#get_text ()) in
        box#misc#set_sensitive false;
        Gtk_utils.async ~parent:box (fun () ->
            Lwt.catch
              (fun () ->
                 Zeroinstall.Gui.send_bug_report role.Zeroinstall.Solver.iface message >>= fun reply ->
                 box#destroy ();
                 Alert_box.report_info ~title:"Report Sent OK" reply;
                 Lwt.return ()
              )
              (fun ex ->
                 box#misc#set_sensitive true;
                 Alert_box.report_error ~parent:box ex;
                 Lwt.return ()
              )
        )
  );

  box#set_default_size
    ~width:(Gdk.Screen.width () / 2)
    ~height:(-1);

  box#show ()
