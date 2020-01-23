(* Copyright (C) 2020, Thomas Leonard
   See the README file for details, or visit http://0install.net. *)

open Support
open General

(* Probably we should use a simple timestamp file for the last-checked
   time and attach the stability ratings to the interface, not the feed. *)
type t = {
  last_checked : float option;
  user_stability : Stability.t XString.Map.t;
}

let load config feed_url =
  match Paths.Config.(first (feed feed_url)) config.paths with
  | None -> { last_checked = None; user_stability = XString.Map.empty }
  | Some path ->
      let root = Qdom.parse_file config.system path in
      let last_checked =
        match ZI.get_attribute_opt "last-checked" root with
        | None -> None
        | Some time -> Some (float_of_string time)
      in
      let stability = ref XString.Map.empty in
      root |> ZI.iter ~name:"implementation" (fun impl ->
        let id = ZI.get_attribute "id" impl in
        match ZI.get_attribute_opt Constants.FeedConfigAttr.user_stability impl with
        | None -> ()
        | Some s -> stability := XString.Map.add id (Stability.of_string ~from_user:true s) !stability
      );
      { last_checked; user_stability = !stability; }

let save config feed_url {last_checked; user_stability} =
  let feed_path = Paths.Config.(save_path (feed feed_url)) config.paths in
  let attrs =
    match last_checked with
    | None -> Qdom.AttrMap.empty
    | Some last_checked -> Qdom.AttrMap.singleton "last-checked" (Printf.sprintf "%.0f" last_checked) in
  let child_nodes = user_stability |> XString.Map.map_bindings (fun id stability ->
    ZI.make "implementation" ~attrs:(
      Qdom.AttrMap.singleton Constants.FeedAttr.id id
      |> Qdom.AttrMap.add_no_ns Constants.FeedConfigAttr.user_stability (Stability.to_string stability)
    )
  ) in
  let root = ZI.make ~attrs ~child_nodes "feed-preferences" in
  feed_path |> config.system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
    Qdom.output (`Channel ch |> Xmlm.make_output) root;
  )

let update config url f =
  load config url |> f |> save config url

let update_last_checked_time config url =
  update config url (fun t -> {t with last_checked = Some config.system#time})

let stability id t = XString.Map.find_opt id t.user_stability

let with_stability id rating t =
  { t with user_stability =
      match rating with
      | None -> XString.Map.remove id t.user_stability
      | Some rating -> XString.Map.add id rating t.user_stability
  }
