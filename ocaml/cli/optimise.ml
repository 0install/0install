(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** The "0install store optimise" command *)

open Options
open Zeroinstall.General
open Support
open Support.Common

module U = Support.Utils
module Manifest = Zeroinstall.Manifest

let are_already_linked (system:system) a b =
  match system#lstat a, system#lstat b with
  | Some ai, Some bi ->
      ai.Unix.st_dev = bi.Unix.st_dev &&
      ai.Unix.st_ino = bi.Unix.st_ino
  | _ -> Safe_exn.failf "Missing files comparing %s and %s" a b

let are_byte_identical (system:system) a b =
  a |> system#with_open_in [Open_rdonly;Open_binary] (fun ia ->
    b |> system#with_open_in [Open_rdonly;Open_binary] (fun ib ->
      let rec loop () =
        let adata = U.read_upto 100 ia in
        let bdata = U.read_upto 100 ib in
        if adata <> bdata then false
        else if adata = "" then true
        else loop () in
      loop ()
    )
  )

(** Keep 'a', delete 'b' and hard-link to 'a' *)
let link (system:system) a b ~tmpfile =
  if not (are_byte_identical system a b) then (
    log_warning "Files should be identical, but they're not!\n%s\n%s" a b
  ) else (
    let b_dir = Filename.dirname b in
    let b_dir_info = system#lstat b_dir |? lazy (Safe_exn.failf "Can't lstat %s!" b_dir) in
    let old_mode = b_dir_info.Unix.st_perm in
    system#chmod b_dir (old_mode lor 0o200);	(* Need write access briefly *)
    U.finally_do (fun () -> system#chmod b_dir old_mode) ()
      (fun () ->
        system#hardlink a tmpfile;
        if on_windows then system#unlink b;
        try system#rename tmpfile b
        with ex ->
          system#unlink tmpfile;
          raise ex
      )
  )

type size = Int64.t

type report = {
  mutable uniq_size : size;
  mutable dup_size : size;
  mutable already_linked : size;
  mutable man_size : size;
}

let optimise_impl system stats first_copy ~tmpfile impl_dir impl =
  let digest = Manifest.parse_digest impl in
  let manifest_path = impl_dir +/ impl +/ ".manifest" in
  let ms = U.read_file system manifest_path in

  if fst digest = "sha1" then ()
  else (
    stats.man_size <- Int64.add stats.man_size (Int64.of_int @@ String.length ms);

    let rec scan dir_path dir_items =
      dir_items |> List.iter (fun (name, item) ->
        match item with
        | `Dir items -> scan (dir_path +/ name) items
        | `Symlink (_, size) -> stats.uniq_size <- Int64.add stats.uniq_size size
        | `File info ->
            let (_x, _hash, _mtime, size) = info in
            let new_full = dir_path +/ name in
            match Hashtbl.find_opt first_copy info with
            | None ->
                Hashtbl.add first_copy info new_full;
                stats.uniq_size <- Int64.add stats.uniq_size size
            | Some first_full ->
                if are_already_linked system first_full new_full then (
                  stats.already_linked <- Int64.add stats.already_linked size
                ) else (
                  link system first_full new_full ~tmpfile;
                  stats.dup_size <- Int64.add stats.dup_size size
                )
      ) in
    scan (impl_dir +/ impl) (Manifest.parse_manifest ms)
  )

(** Scan an implementation cache directory for duplicate files, and
    hard-link any duplicates together to save space. *)
let optimise system impl_dir =
  let first_copy = Hashtbl.create 1024 in		(* `File tuple -> path *)
  let stats = {
    uniq_size = Int64.zero;
    dup_size = Int64.zero;
    already_linked = Int64.zero;
    man_size = Int64.zero;
  } in

  (* Find an unused filename we can used during linking *)
  let tmpfile =
    let rec mktmp = function
      | 0 -> Safe_exn.failf "Failed to generate temporary file name!"
      | n ->
          let tmppath = impl_dir +/ Printf.sprintf "optimise-%x" (Random.int 0x3fffffff) in
          if system#file_exists tmppath then mktmp (n - 1)
          else tmppath in
    mktmp 10 in

  let dirs =
    match system#readdir impl_dir with
    | Error ex -> raise ex
    | Ok items -> items in
  let total = Array.length dirs in
  let msg = ref "" in
  let clear () =
    let blank = String.make (String.length !msg) ' ' in
    Printf.printf "\r%s\r%!" blank
  in
  dirs |> Array.iteri (fun i impl ->
    clear ();
    Printf.printf "[%d / %d] Reading manifests...%!" i total;
    try optimise_impl system stats first_copy ~tmpfile impl_dir impl
    with Safe_exn.T e -> clear (); log_warning "Skipping '%s': %a" impl Safe_exn.pp e
  );
  clear ();
  stats

let handle options flags args =
  Support.Argparse.iter_options flags (Common_options.process_common_option options);
  let config = options.config in
  let system = config.system in

  let cache_dir =
    match args with
    | [] -> List.hd options.config.stores
    | [dir] -> U.abspath system dir
    | _ -> raise (Support.Argparse.Usage_error 1) in

  if not (U.is_dir system cache_dir) then (
    Safe_exn.failf "Not a directory: '%s'" cache_dir
  );

  let impl_name = Filename.basename cache_dir in
  if impl_name <> "implementations" then (
    Safe_exn.failf "Cache directory should be named 'implementations', not '%s' (in '%s')" impl_name cache_dir
  );

  let print fmt = Format.fprintf options.stdout (fmt ^^ "@.") in
  print "Optimising %s" cache_dir;

  let {uniq_size; dup_size; already_linked; man_size} = optimise config.system cache_dir in
  print "Original size  : %s (excluding the %s of manifests)" (U.format_size (Int64.add uniq_size dup_size)) (U.format_size man_size);
  print "Already saved  : %s" (U.format_size already_linked);
  if dup_size = Int64.zero then (
    print "No duplicates found; no changes made."
  ) else (
    print "Optimised size : %s" (U.format_size uniq_size);
    let perc = (100.0 *. Int64.to_float dup_size) /. (Int64.to_float uniq_size +. Int64.to_float dup_size) in
    print "Space freed up : %s (%.2f%%)" (U.format_size dup_size) perc
  );
  print "Optimisation complete."
