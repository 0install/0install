(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Support.Common
module U = Support.Utils

type package_info = {
  version : Version.t;
  machine : Arch.machine option;
  installed : bool;
  retrieval_method : Impl.distro_retrieval_method;
}

type packagekit_id = string
type size = Int64.t

type query_result = {
  results : package_info list;
  problems : string list;
}

class type ui =
  object
    method monitor : Downloader.download -> unit
    method confirm : string -> [`Ok | `Cancel] Lwt.t
    method impl_added_to_store : unit
  end

class type packagekit =
  object
    method status : [`Ok | `Unavailable of string] Lwt.t
    method get_impls : string -> query_result
    method check_for_candidates : 'a. ui:(#ui as 'a) -> hint:string -> string list -> unit Lwt.t
    method install_packages : 'a. (#ui as 'a) -> (Impl.distro_implementation * Impl.distro_retrieval_method) list -> [ `Ok | `Cancel ] Lwt.t
  end

(** PackageKit refuses to process more than 100 requests per transaction, so never ask for more than this in a single request. *)
let max_batch_size = 100

(** Wait for a task to complete, but ignore the actual return value. *)
let lwt_wait_for task =
  task >|= ignore

let add_package details ~package_id ~summary =
  log_info "packagekit: resolved %s: %s" package_id summary;
  match Str.bounded_split_delim U.re_semicolon package_id 4 with
  | [package_name; version; machine; repo] ->
      Hashtbl.add details package_name begin
        match Version.try_cleanup_distro_version version with
        | None ->
            `Error (Printf.sprintf "Failed to parse version string '%s' for '%s'" version package_name)
        | Some version ->
            let machine = Support.System.canonical_machine machine in
            `Ok {
              version;
              machine = Arch.parse_machine machine;
              installed = (repo = "installed");
              retrieval_method = { Impl.
                distro_size = None;    (* Gets filled in later *)
                distro_install_info = ("packagekit", package_id)
              }
            }
      end
  | _ ->
      log_warning "Malformed package ID returned by PackageKit: '%s'" package_id

(** Convert short names to PackageKit IDs (e.g. "gnupg" -> "gnupg;2.0.22;x86_64;arch") *)
let resolve proxy package_names =
  let details = Hashtbl.create 10 in
  Lwt.catch
    (fun () -> Packagekit_stubs.summaries proxy ~package_names (add_package details))
    (function
      | Safe_exception _ as ex ->
        (* This is a bit broken. PackageKit seems to abort on the first unknown package, so we
         * lose the remaining results. Still, something is better than nothing... *)
        log_debug ~ex "Error resolving %s with PackageKit" (String.concat "," package_names);
        Lwt.return ()
      | ex -> Lwt.fail ex
    )
  >|= fun () ->
  let add map name = map |> StringMap.add name (Hashtbl.find_all details name) in
  package_names |> List.fold_left add StringMap.empty

(** Get the sizes of the candidate packages. *)
let get_sizes proxy = function
  | [] -> Lwt.return StringMap.empty      (* PackageKit can't handle empty queries *)
  | package_ids ->
      let details = ref StringMap.empty in
      let add ~package_id ~size =
        details := !details |> StringMap.add package_id size in
      Packagekit_stubs.sizes proxy ~package_ids add >|= fun () ->
      !details

let get_packagekit_id = function
  | {Impl.distro_install_info = ("packagekit", id); _} -> id
  | _ -> assert false

let rec get_total acc = function
  | [] -> Some acc
  | (_impl, {Impl.distro_size = Some size; _}) :: xs -> get_total (Int64.add acc size) xs
  | (_impl, {Impl.distro_size = None; _}) :: _ -> None

let with_finished cb =
  let finished, set_finished = Lwt_react.S.create false in
  Lwt.finalize
    (fun () -> cb finished)
    (fun () ->
       set_finished true;
       Lwt.return ()
    )

(** Install distribution packages. *)
let install (ui:#ui) proxy items =
  let packagekit_ids = items |> List.map (fun (_impl, rm) -> get_packagekit_id rm) in
  let total_size = get_total Int64.zero items in
  with_finished @@ fun finished ->
    let cancelled = ref false in
    Packagekit_stubs.run_transaction proxy (fun switch proxy ->
      Packagekit_stubs.Transaction.monitor ~switch proxy >>= fun percentage ->
      let progress = Lwt_react.S.l2 (fun perc finished ->
        match total_size with
        | Some size when size <> Int64.zero ->
            let frac = min 1.0 @@ (Int32.to_float perc) /. 100. in
            (Int64.of_float (frac *. (Int64.to_float size)), total_size, finished)
        | _ -> (Int64.of_int32 perc, None, finished)
      ) percentage finished in
      let cancel () =
        if not !cancelled then (
          cancelled := true;
          log_info "Cancelling PackageKit installation";
          Lwt.catch
            (fun () -> Packagekit_stubs.Transaction.cancel proxy)
            (fun ex ->
               log_warning ~ex "packagekit: cancel failed";
               Lwt.return ()
            )
        ) else Lwt.return () in
      (* Notify the start of all downloads (we share the overall progress between them currently). *)
      items |> List.iter (fun (impl, _rm) ->
        let main_feed =
          match Impl.get_attr_ex Constants.FeedAttr.from_feed impl |> Feed_url.parse with
          | `Distribution_feed main_feed -> main_feed
          | (`Local_feed x | `Remote_feed x) as main_feed -> log_warning "Not a distribution feed: %s" x; main_feed in
        ui#monitor Downloader.({cancel; url = "(packagekit)"; progress; hint = Some (Feed_url.format_url main_feed)})
      );
      Packagekit_stubs.Transaction.install_packages proxy packagekit_ids
    ) >>= fun () ->
    (* Mark each package as now installed (possibly we should do this individually in a signal callback instead). *)
    items |> List.iter (fun (impl, _rm) ->
      let `Package_impl info = impl.Impl.impl_type in
      info.Impl.package_state <- `Installed
    );
    ui#impl_added_to_store;
    Lwt.return (if !cancelled then `Cancel else `Ok)

let fail_on_exn queries fn =
  Lwt.catch fn
    (fun ex ->
      List.iter (fun (_, resolver) -> Lwt.wakeup_exn resolver ex) queries;
      Lwt.return ()
    )

(* The list of packagekit IDs that were successfull resolved. *)
let success_ids resolutions =
  StringMap.fold (fun _ infos acc ->
    infos |> List.fold_left (fun acc info ->
      match info with
      | `Ok info -> get_packagekit_id info.retrieval_method :: acc
      | `Error _ -> acc
    ) acc
  ) resolutions []

(* Resolve a query with its results and problems. *)
let resolve_query ~resolutions ~sizes (name, resolver) =
  let impls = StringMap.find name resolutions |> default [] in
  let problems = ref [] in
  if impls = [] then
    problems := Printf.sprintf "'%s' details not in PackageKit response" name :: !problems;
  (* Update retrieval method with the size information *)
  let add_size = function
    | `Error msg -> problems := Printf.sprintf "%s: %s" name msg :: !problems; None
    | `Ok impl ->
    let rm = impl.retrieval_method in
    let packagekit_id = get_packagekit_id rm in
    match StringMap.find packagekit_id sizes with
    | Some _ as size -> Some {impl with retrieval_method = {rm with Impl.distro_size = size}}
    | None ->
        log_info "No size returned for '%s'" packagekit_id;
        Some impl in
  let results = U.filter_map add_size impls in
  Lwt.wakeup resolver {
    results;
    problems = !problems;
  }

(* Send a single PackageKit transaction for these packages. *)
let fetch_batch proxy queries =
  log_info "packagekit: requesting details for %s" (String.concat ", " (List.map fst queries));
  fail_on_exn queries @@ fun () ->
  (* Convert short names to PackageKit IDs *)
  resolve proxy (List.map fst queries) >>= fun resolutions ->
  let package_ids = success_ids resolutions in
  if List.length package_ids > 0 then
    log_debug "packagekit: requesting package sizes for %s" (String.concat ", " (List.map String.escaped package_ids))
  else
    log_debug "packagekit: no packages found";
  (* Collect package sizes *)
  Lwt.catch
    (fun () -> get_sizes proxy package_ids)
    (fun ex ->
       log_warning ~ex "packagekit: GetDetails failed";
       Lwt.return StringMap.empty
    )
  >|= fun sizes ->
  log_info "packagekit: fetch_batch done";
  List.iter (resolve_query ~resolutions ~sizes) queries

module Candidates : sig
  type t
  val make : unit -> t
  val get : t -> string -> query_result Lwt.t option
  val ensure_fetching : t -> string -> [`In_progress of query_result Lwt.t | `New_task of query_result Lwt.t * query_result Lwt.u]
end = struct
  type t = (string, query_result Lwt.t) Hashtbl.t

  let make () = Hashtbl.create 10

  let get t package_name =
    try Some (Hashtbl.find t package_name)
    with Not_found -> None

  let ensure_fetching t name =
    let start () =
      let task, waker = Lwt.task () in
      Hashtbl.replace t name task;
      `New_task (task, waker) in
    match get t name with
    | None -> start ()
    | Some existing_task ->
      match Lwt.state existing_task with
      | Lwt.Return _ | Lwt.Fail _ -> start ()
      | Lwt.Sleep -> `In_progress existing_task
end

let with_simple_progress fn =
  let progress, set_progress = Lwt_react.S.create (Int64.zero, None, false) in
  Lwt.finalize
    (fun () -> fn progress)
    (fun () ->
       set_progress (Int64.zero, None, true);
       Lwt.return ()
    )

let make lang_spec =
  let proxy = lazy (Packagekit_stubs.connect lang_spec) in

  object (_ : packagekit)
    val candidates = Candidates.make ()

    (** Names of packages we're about to issue a query for and their resolvers/wakers. *)
    val mutable next_batch = []

    method status =
      Lazy.force proxy >|= function
      | `Ok _proxy -> `Ok
      | `Unavailable _ as un -> un

    (** Add any cached candidates.
        The candidates are those discovered by a previous call to [check_for_candidates].
        @param package_name the distribution's name for the package *)
    method get_impls package_name =
      match Candidates.get candidates package_name with
      | None -> { results = []; problems = [] }
      | Some task ->
      match Lwt.state task with
      | Lwt.Sleep -> { results = []; problems = [] }                 (* Fetch still in progress *)
      | Lwt.Fail ex -> { results = []; problems = [Printexc.to_string ex] }     (* Fetch failed *)
      | Lwt.Return packages -> packages

    (** Request information about these packages from PackageKit. *)
    method check_for_candidates ~ui ~hint = function
      | [] -> Lwt.return ()
      | package_names ->
        Lazy.force proxy >>= function
        | `Unavailable _ -> Lwt.return ()
        | `Ok proxy ->
          with_simple_progress @@ fun progress ->
          Lwt.catch (fun () ->
              let waiting_for = ref [] in

              let cancel () = !waiting_for |> List.iter Lwt.cancel; Lwt.return () in
              ui#monitor Downloader.({cancel; url = "(packagekit query)"; progress; hint = Some hint});

              log_info "Querying PackageKit for '%s'" (String.concat ", " package_names);

              let do_batch () =
                let next = next_batch in
                next_batch <- [];
                if next <> [] then
                  U.async (fun () -> fetch_batch proxy next) in

              (* Create a promise for each package and add it to [candidates].
               * Pass the resolvers to fetch_batch (in groups of up to [max_batch_size]).
               * If we're already fetching, just take the existing promise.
              *)
              package_names |> List.iter (fun name ->
                  match Candidates.ensure_fetching candidates name with
                  | `In_progress existing_task ->
                    waiting_for := lwt_wait_for existing_task :: !waiting_for
                  | `New_task (task, waker) ->
                    waiting_for := lwt_wait_for task :: !waiting_for;
                    next_batch <- (name, waker) :: next_batch;
                    if List.length next_batch = max_batch_size then do_batch ()
                );

              (* Yield briefly, so that other packages can be added to the final batch. *)
              Lwt_main.yield () >>= fun () ->
              (* (note: next_batch might also have become empty, if someone else added our items to their batch) *)
              do_batch ();

              Lwt.join !waiting_for
            ) (function
              | Lwt.Canceled -> Lwt.return ()
              | ex ->
                log_warning ~ex "Error querying PackageKit";
                Lwt.return ()
            )

    method install_packages (ui:#ui) items : [ `Ok | `Cancel ] Lwt.t =
      let packagekit_ids = items |> List.map (fun (_impl, rm) -> get_packagekit_id rm) in
      ui#confirm (
        "The following components need to be installed using native packages. \
         These come from your distribution, and should therefore be trustworthy, but they also \
         run with extra privileges. In particular, installing them may run extra services on your \
         computer or affect other users. You may be asked to enter a password to confirm. The \
         packages are:\n\n- " ^ (String.concat "\n- " packagekit_ids)
      ) >>= function
      | `Cancel -> Lwt.return `Cancel
      | `Ok ->
          Lazy.force proxy >>= function
          | `Ok pk -> install ui pk items
          | `Unavailable _ -> failwith "BUG: PackageKit has disappeared!"
  end
