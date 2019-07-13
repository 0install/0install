(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Keeping track of which keys we trust *)

open General
open Support
open Support.Common
module Basedir = Support.Basedir
module G = Support.Gpg
module U = Support.Utils
module Q = Support.Qdom

module TRUST_NS = struct
  let ns = "http://zero-install.sourceforge.net/2007/injector/trust"
  let prefix_hint = "trust"
end
module TRUST = Support.Qdom.NsQuery (TRUST_NS)

class type watcher =
  object
    method notify : unit
  end

(** A database of trusted keys. *)
class trust_db config =
  (* In dry_run mode, we don't save the database to disk, so we need to store any changes in memory. *)
  let dry_run_db = ref None in
  let watchers = ref [] in

  let get_db () =
    (* This is a bit inefficient... (could cache things) *)
    match !dry_run_db with
    | Some db -> db
    | None ->
        match Paths.Config.(first trust_db) config.paths with
        | None -> XString.Map.empty
        | Some path ->
            let root = Q.parse_file config.system path in
            root |> TRUST.fold_left ~init:XString.Map.empty ~name:"key" (fun keys key ->
              let domains =
                key |> TRUST.fold_left ~init:XString.Set.empty ~name:"domain" (fun map domain ->
                  XString.Set.add (TRUST.get_attribute "value" domain) map
                ) in
              XString.Map.add (TRUST.get_attribute "fingerprint" key) domains keys
            ) in

  let get_domains fingerprint db =
    default XString.Set.empty @@ XString.Map.find_opt fingerprint db in

  let is_trusted db ~domain fingerprint =
    let domains = get_domains fingerprint db in
    XString.Set.mem domain domains || XString.Set.mem "*" domains in

  let save db =
    let db_file = Paths.Config.(save_path trust_db) config.paths in
    if config.dry_run then (
      Dry_run.log "would update trust database %s" db_file;
      dry_run_db := Some db
    ) else (
      let key_elems = db |> XString.Map.map_bindings (fun fingerprint domains ->
        let domain_elems = domains |> XString.Set.elements |> List.map (fun domain ->
          TRUST.make "domain" ~attrs:(Q.AttrMap.singleton "value" domain)
        ) in
        TRUST.make "key"
          ~child_nodes:domain_elems
          ~attrs:(Q.AttrMap.singleton "fingerprint" fingerprint)
      ) in
      let root = TRUST.make ~child_nodes:key_elems "trusted-keys" in

      db_file |> config.system#atomic_write [Open_wronly; Open_binary] ~mode:0o644 (fun ch ->
        Q.output (`Channel ch |> Xmlm.make_output) root;
      );
      !watchers |> List.iter (fun (obj:watcher) -> obj#notify);
    ) in

  object
    method is_trusted ~domain fingerprint : bool =
      let db = get_db () in
      is_trusted db ~domain fingerprint

    (** Return the set of domains in which this key is trusted.
        If the list includes '*' then the key is trusted everywhere. *)
    method get_trust_domains fingerprint =
      let db = get_db () in
      get_domains fingerprint db

    (** Returns a map from keys to the domains in which they are trusted. *)
    method get_db = get_db ()

    (** Return the set of keys trusted for this domain. *)
    method get_keys_for_domain domain =
      let db = get_db () in
      let check_key key domains results =
        if XString.Set.mem domain domains then XString.Set.add key results
        else results in
      XString.Map.fold check_key db XString.Set.empty

    (* Add key to the list of trusted fingerprints. *)
    method trust_key ~domain fingerprint =
(*
      if domain = "*" then
        log_warning "Calling trust_key() without a domain is deprecated";
*)

      let db = get_db () in
      if not (is_trusted db ~domain fingerprint) then (
        if config.dry_run then
          Dry_run.log "would trust key %s for %s" fingerprint domain; (* (and continue...) *)

        (* Ensure fingerprint is valid *)
        let re_fingerprint = Str.regexp "[0-9A-Fa-f]+" in
        assert (Str.string_match re_fingerprint fingerprint 0);

        let domains = get_domains fingerprint db in

        let db = XString.Map.add fingerprint (XString.Set.add domain domains) db in

        save db
      )

    method untrust_key ~domain fingerprint =
      let db = get_db () in
      if config.dry_run then
        Dry_run.log "would untrust key %s for %s" fingerprint domain; (* (and continue...) *)

      let domains = get_domains fingerprint db in
      let domains = XString.Set.remove domain domains in
      let db =
        if XString.Set.is_empty domains then
          XString.Map.remove fingerprint db
        else
          XString.Map.add fingerprint domains db in

      save db

    (** Return the timestampt of the oldest signature we trust on this feed, or None if we don't
     * trust any of them. *)
    method oldest_trusted_sig domain sigs =
      let db = get_db () in
      let oldest = ref None in
      sigs |> List.iter (function
        | G.ValidSig {G.fingerprint; G.timestamp} ->
            if is_trusted db ~domain fingerprint then (
              match !oldest with
              | Some old_best when timestamp > old_best -> ()
              | _ -> oldest := Some timestamp
            )
        | G.BadSig _ | G.ErrSig _ -> ()
      );
      !oldest

    method add_watcher obj =
      watchers := obj :: !watchers;
      fun () -> watchers := !watchers |> List.filter ((!=) obj)
  end

let re_domain = Str.regexp "^https?://\\([^/]*@\\)?\\([^*/]+\\)/"

(* Extract the trust domain for a URL. *)
let domain_from_url (`Remote_feed url) =
  if Str.string_match re_domain url 0 then
    Str.matched_group 2 url
  else
    Safe_exn.failf "Failed to parse HTTP URL '%s'" url
