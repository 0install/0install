(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support
open Support.Common
open Gtk_common

module Progress = Zeroinstall.Progress
module Trust = Zeroinstall.Trust
module G = Support.Gpg
module U = Support.Utils

let left text =
  GMisc.label ~text ~selectable:true ~xalign:0.0 ~yalign:0.5

let pretty_fp fingerprint =
  let b = Buffer.create (String.length fingerprint * 2) in
  let chunks = String.length fingerprint / 4 in
  for i = 0 to chunks - 1 do
    if i > 0 then
      Buffer.add_char b ' ';
    Buffer.add_substring b fingerprint (i * 4) 4;
  done;
  let tail = chunks * 4 in
  Buffer.add_substring b fingerprint tail (String.length fingerprint - tail);
  Buffer.contents b

let make_hint vote hint_text =
  let stock =
    match vote with
    | Progress.Good -> `YES
    | Progress.Bad -> `DIALOG_WARNING in
  let hint_icon = GMisc.image ~stock ~icon_size:`BUTTON ~xalign:0.0 ~yalign:0.0 () in
  let hint = left hint_text ~line_wrap:true () in
  let hint_hbox = GPack.hbox ~homogeneous:false ~spacing:4 () in
  hint_hbox#pack (hint_icon :> GObj.widget) ~expand:false ~fill:true;
  hint_hbox#pack (hint :> GObj.widget) ~expand:true ~fill:true;
  hint_hbox

let make_hints_area result hints =
  let box = GPack.vbox ~border_width:8 ~homogeneous:false ~spacing:4 () in

  let add_hints hints =
    if Lwt.state result = Lwt.Sleep then (
      let hints =
        if hints = [] then [(Progress.Bad, "Warning: Nothing known about this key!")] else hints in
      hints |> List.iter (fun (vote, msg) ->
        box#pack ~expand:false ~fill:true (make_hint vote msg :> GObj.widget)
      )
    ) in

  begin match Lwt.state hints with
  | Lwt.Sleep ->
      let label = left "Waiting for response from key information server..." () in
      box#pack ~expand:false ~fill:true (label :> GObj.widget);
      Gtk_utils.async (fun () ->
        hints >|= fun hints ->
        label#destroy ();
        add_hints hints
      )
  | Lwt.Return hints -> add_hints hints
  | Lwt.Fail ex -> raise ex end;

  box

let confirm_keys_help = Help_box.create "Trust Help" [
("Overview",
"When you run a program, it typically has access to all your files and can generally do \
anything that you're allowed to do (delete files, send emails, etc). So it's important \
to make sure that you don't run anything malicious.");

("Digital signatures",
"Each software author creates a 'key-pair'; a 'public key' and a 'private key'.\
\n\n\
When a programmer releases some software, they sign it with their private key (which no-one \
else has). When you download it, 0install checks the signature using the public key, thus \
proving that it came from them and hasn't been tampered with.");

("Trust",
"After 0install has checked that the software hasn't been modified since it was signed with \
the private key, you still have the following problems:\
\n\n\
1. Does the public key you have really belong to the author?\n\
2. Even if the software really did come from that person, do you trust them?");

("Key fingerprints",
"To confirm (1), you should compare the public key you have with the genuine one. To make this \
easier, 0install displays a 'fingerprint' for the key. Look in mailing list postings or some \
other source to check that the fingerprint is right (a different key will have a different \
fingerprint).\
\n\n\
You're trying to protect against the situation where an attacker breaks into a web site \
and puts up malicious software, signed with the attacker's private key, and puts up the \
attacker's public key too. If you've downloaded this software before, you \
should be suspicious that you're being asked to confirm another key!");

("Reputation",
"In general, most problems seem to come from malicous and otherwise-unknown people \
replacing software with modified versions, or creating new programs intended only to \
cause damage. So, check your programs are signed by a key with a good reputation!");
]

(** Check the key-info server's results for these keys. If we don't know any of them,
 * ask for extra confirmation from the user.
 * @return true if we should continue and trust the keys. *)
let confirm_unknown_keys ~parent to_trust valid_sigs =
  let unknown = to_trust |> List.filter (fun fpr ->
    let hints = List.assoc fpr valid_sigs in
    match Lwt.state hints with
    | Lwt.Fail _ | Lwt.Sleep -> true  (* Still waiting => unknown *)
    | Lwt.Return hints ->
        (* Unknown if we didn't get any Good votes *)
        not (List.exists (fun (vote, _msg) -> vote = Progress.Good) hints)
  ) in
  let confirm message =
    let result, set_result = Lwt.wait () in
    let box = GWindow.message_dialog
      ~message
      ~message_type:`QUESTION
      ~parent
      ~destroy_with_parent:true
      ~buttons:GWindow.Buttons.ok_cancel
      ~position:`CENTER
      () in
    box#action_area#set_spacing 4;
    box#action_area#set_border_width 4;
    box#connect#response ==> (function
      | `OK -> Lwt.wakeup set_result true; box#destroy ()
      | `DELETE_EVENT | `CANCEL -> Lwt.wakeup set_result false; box#destroy ()
    );
    box#show ();
    result in
  match unknown with
  | [] -> Lwt.return true
  | [_] -> confirm "WARNING: you are confirming a key which was not known to the key server. Are you sure?"
  | _   -> confirm "WARNING: you are confirming keys which were not known to the key server. Are you sure?"

let frame ~title ~content (parent:GPack.box) =
  let frame = GBin.frame ~shadow_type:`NONE () in
  let label = GMisc.label
    ~markup:(Printf.sprintf "<b>%s</b>" title)    (* Escaping? *)
    () in
  frame#set_label_widget (Some (label :> GObj.widget));
  frame#add (content :> GObj.widget);
  parent#pack (frame :> GObj.widget) ~expand:false ~fill:true

let confirm_keys gpg trust_db ?parent feed_url valid_sigs =
  assert (valid_sigs <> []);
  let n_sigs = List.length valid_sigs in
  let `Remote_feed url = feed_url in

  valid_sigs |> List.map fst |> G.load_keys gpg >>= fun key_names ->

  let result, set_result = Lwt.wait () in
  let dialog = GWindow.dialog
    ?parent
    ~title:"Confirm trust"
    ~position:`CENTER
    () in
  dialog#action_area#set_border_width 4;

  let vbox = GPack.vbox
    ~homogeneous:false
    ~spacing:4
    ~border_width:4
    () in

  dialog#vbox#pack ~expand:true ~fill:true (vbox :> GObj.widget);

  let label = left (Printf.sprintf "Checking: %s" url) ~xpad:4 ~ypad:4 () in
  vbox#pack ~expand:false ~fill:true (label :> GObj.widget);

  let domain = Trust.domain_from_url feed_url in

  begin match trust_db#get_keys_for_domain domain |> XString.Set.elements with
    | [] -> Lwt.return ["None"]
    | keys ->
      G.load_keys gpg keys >|= XString.Map.map_bindings
        (fun fp info ->
          Printf.sprintf "%s\n(fingerprint: %s)" (default "?" info.G.name) (pretty_fp fp)
        )
  end >>= fun descriptions ->

  frame
    ~title:(Printf.sprintf "Keys already approved for '%s'" domain)
    ~content:(left (String.concat "\n" descriptions) ~xpad:8 ~ypad:4 ())
    vbox;

  let label =
    match valid_sigs with
    | [_] -> "This key signed the feed:"
    | _ -> "These keys signed the feed:" in
  vbox#pack ~expand:false ~fill:true (left label ~xpad:4 ~ypad:4 () :> GObj.widget);

  let notebook = GPack.notebook
    ~show_border:false
    ~show_tabs:(n_sigs > 1)
    () in

  dialog#add_button_stock `HELP `HELP;
  (* Lablgtk uses the wrong response code for HELP, so we have to do this manually. *)
  let actions = dialog#action_area in
  actions#set_child_secondary (List.hd actions#children) true;

  dialog#add_button_stock `CANCEL `CANCEL;
  dialog#add_button_stock `ADD `OK;
  dialog#set_default_response `OK;

  let trust_checkboxes = ref [] in

  (* The OK button is available whenever at least one key is selected to be trusted. *)
  let update_ok_button () =
    !trust_checkboxes
    |> List.exists (fun (_fpr, box) -> box#active)
    |> dialog#set_response_sensitive `OK in

  valid_sigs |> List.iter (fun (fpr, hints) ->
    let name =
      XString.Map.find_opt fpr key_names
      |> pipe_some (fun info -> info.G.name)
      |> default "<unknown>" in
    let page = GPack.vbox ~homogeneous:false ~spacing:4 ~border_width:8 () in
    frame
      ~title:"Fingerprint"
      ~content:(left (pretty_fp fpr) ~xpad:8 ~ypad:4 ())
      page;
    frame
      ~title:"Claimed identity"
      ~content:(left name ~xpad:8 ~ypad:4 ())
      page;
    frame
      ~title:"Unreliable hints database says"
      ~content:(make_hints_area result hints)
      page;

    let already_trusted = trust_db#get_trust_domains fpr |> XString.Set.elements in
    if already_trusted <> [] then (
      frame
        ~title:"You already trust this key for these domains"
        ~content:(left (String.concat "\n" already_trusted) ~xpad:8 ~ypad:4 ())
        page
    );

    let checkbox = GButton.check_button
      ~use_mnemonic:true
      ~show:(n_sigs > 1)
      ~label:"_Trust this key" () in
    trust_checkboxes := (fpr, checkbox) :: !trust_checkboxes;
    page#pack ~expand:false ~fill:true (checkbox :> GObj.widget);
    checkbox#connect#toggled ==> (fun _cb -> update_ok_button ());
    let tab_label = (GMisc.label ~text:name () :> GObj.widget) in
    append_page notebook ~tab_label (page :> GObj.widget);
  );
  (List.hd !trust_checkboxes |> snd)#set_active true;

  vbox#pack ~expand:true ~fill:true (notebook :> GObj.widget);

  dialog#connect#response ==> (function
    | `OK ->
        let to_trust = !trust_checkboxes |> List.filter_map (fun (fpr, box) ->
          if box#active then Some fpr else None
        ) in
        assert (to_trust <> []);
        let ok = confirm_unknown_keys ~parent:dialog to_trust valid_sigs in
        Gtk_utils.async ~parent:dialog (fun () ->
          ok >|= function
          | false -> ()
          | true ->
              Lwt.wakeup set_result to_trust;
              dialog#destroy ()
        )
    | `DELETE_EVENT | `CANCEL -> Lwt.wakeup set_result []; dialog#destroy ()
    | `HELP -> confirm_keys_help#display
  );

  dialog#show ();
  result
