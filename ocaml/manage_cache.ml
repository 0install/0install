(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install store manage" command *)

open Options
open Zeroinstall.General
open Support.Common

module F = Zeroinstall.Feed
module FC = Zeroinstall.Feed_cache
module P = Zeroinstall.Python
module U = Support.Utils

let rec size_of_item system path =
  match system#lstat path with
  | None -> 0.0
  | Some info ->
      match info.Unix.st_kind with
      | Unix.S_REG | Unix.S_LNK -> float_of_int info.Unix.st_size
      | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> log_warning "Bad file kind for %s" path; 0.0
      | Unix.S_DIR ->
          match system#readdir path with
          | Success items -> items |> Array.fold_left (fun acc item -> acc +. size_of_item system (path +/ item)) 0.0
          | Problem ex -> log_warning ~ex "Can't scan %s" path; 0.0

(** Get the size for an implementation. Get the size from the .manifest if possible. *)
let size_of_impl (system:system) path =
  let man = path +/ ".manifest" in
  match system#lstat man with
  | None -> size_of_item system path
  | Some info ->
      let size = ref @@ float_of_int info.Unix.st_size in    (* (include the size of the .manifest file itself) *)
      system#with_open_in [Open_rdonly; Open_binary] 0 man (fun stream ->
        try
          while true do
            let line = input_line stream in
            match line.[0] with
            | 'X' | 'F' ->
                begin match Str.bounded_split_delim U.re_space line 5 with
                | [_type; _hash; _mtime; item_size; _name] -> size := !size +. float_of_string item_size
                | _ -> () end
            | _ -> ()
          done
        with End_of_file -> ()
      );
      !size

let handle options flags args =
  let config = options.config in
  Support.Argparse.iter_options flags (function
    | #common_option as o -> Common_options.process_common_option options o
  );
  if args <> [] then raise (Support.Argparse.Usage_error 1);
  let gui = options.slave#invoke_async (`List [`String "open-cache-explorer"]) P.expect_null in

  options.slave#invoke (`List [`String "ping"]) P.expect_null;

  let all_digests = Zeroinstall.Stores.get_available_digests config.system config.stores in
  let ok_feeds = ref [] in
  let error_feeds = ref [] in

  (* Look through cached feeds for implementation owners *)
  let all_feed_urls = FC.list_all_feeds config in
  all_feed_urls |> StringSet.iter (fun url ->
    try
      match FC.get_cached_feed config (`remote_feed url) with
      | Some feed -> ok_feeds := feed :: !ok_feeds
      | None -> log_warning "Feed listed but now missing! %s" url
    with ex ->
      log_info ~ex "Error loading feed %s" url;
      error_feeds := `List [`String url; `String (Printexc.to_string ex)] :: !error_feeds
  );

  (* For each feed... *)
  let ok_feeds =
    !ok_feeds |> List.map (fun feed ->
      let cached_impls = ref [] in
      (* For each implementation... *)
      feed.F.implementations |> StringMap.iter (fun _id impl ->
        match impl.F.impl_type with
        | F.CacheImpl info ->
            (* For each digest... *)
            info.F.digests |> List.iter (fun parsed_digest ->
              let digest = Zeroinstall.Manifest.format_digest parsed_digest in
              if Hashtbl.mem all_digests digest then (
                (* Record each cached implementation. *)
                let dir = Hashtbl.find all_digests digest in
                Hashtbl.remove all_digests digest;
                let impl_path = dir +/ digest in
                let info = `Assoc [
                  ("cache-dir", `String dir);
                  ("digest", `String digest);
                  ("version", `String (F.get_attr_ex Zeroinstall.Constants.FeedAttr.version impl));
                  ("arch", `String (Zeroinstall.Arch.format_arch impl.F.os impl.F.machine));
                  ("size", `Float (size_of_impl config.system impl_path));
                ] in
                cached_impls := (impl.F.parsed_version, info) :: !cached_impls
              )
            )
        | F.PackageImpl _ -> ()
        | F.LocalImpl _ -> assert false
      );
      let cached_impls = List.sort compare !cached_impls in
      `Assoc [
        ("url", `String (Zeroinstall.Feed_url.format_url feed.F.url));
        ("name", `String feed.F.name);
        ("summary", `String (default "-" @@ F.get_summary config.langs feed));
        ("in-cache", `List (List.map snd cached_impls));
      ]
    ) in

  let unowned = ref [] in
  let user_dir = List.hd config.stores in
  all_digests |> Hashtbl.iter (fun digest dir ->
    if dir = user_dir then (
      let impl_path = dir +/ digest in
      let item = `Assoc [
        ("path", `String impl_path);
        ("size", `Float (size_of_impl config.system impl_path));
      ] in
      unowned := item :: !unowned
    )
  );

  let request = `List [`String "populate-cache-explorer"; `List ok_feeds; `List !error_feeds; `List !unowned] in
  P.async (fun () -> options.slave#invoke_async request P.expect_null);

  Lwt_main.run gui
