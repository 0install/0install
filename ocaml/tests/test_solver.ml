(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Support.Common
open OUnit
open Zeroinstall

module StringData =
  struct
    type t = string
    let to_string s = s
    let unused = "unused"
  end

module Sat = Support.Sat.MakeSAT(StringData)

open Sat

module EString =
struct
  type t = string
  let compare = compare
  let pp_printer = Format.pp_print_string
  let pp_print_sep = OUnitDiff.pp_comma_separator
end

module ListString = OUnitDiff.ListSimpleMake(EString);;

let set_of_attrs elem : string list =
  let str_list = ListLabels.map elem.Support.Qdom.attrs ~f:(fun ((ns, name), value) ->
    if ns <> "" then
      Printf.sprintf "{%s}%s=%s" ns name value
    else
      Printf.sprintf "%s=%s" name value
  ) in
  List.sort compare str_list

let xml_diff exp actual =
  let open Support.Qdom in
  let p = Printf.printf in
  let rec find_diff a b =
    if snd a.tag <> snd b.tag then (
      p "Tag <%s> vs <%s>\n" (snd a.tag) (snd b.tag); true
    ) else if a.tag <> b.tag then (
      p "Namespace '%s' vs '%s'\n" (fst a.tag) (fst a.tag); true
    ) else (
      assert_equal ~printer:(fun s -> s) (trim a.text_before) (trim b.text_before);
      assert_equal ~printer:(fun s -> s) (trim a.last_text_inside) (trim b.last_text_inside);
      ListString.assert_equal (set_of_attrs a) (set_of_attrs b);
      if List.length a.child_nodes <> List.length b.child_nodes then (
        p "Number of child nodes differs\n"; true
      ) else (
        List.exists2 find_diff a.child_nodes b.child_nodes
      )
    ) in
  if find_diff exp actual then (
    assert (compare_nodes ~ignore_whitespace:true exp actual <> 0);
    assert_equal ~printer:(fun s -> s)
      (to_utf8 exp)
      (to_utf8 actual)
  ) else assert (compare_nodes ~ignore_whitespace:true exp actual = 0)

(** Give every implementation an <archive>, so we think it's installable. *)
let rec make_all_downloable node =
  let open Support.Qdom in
  if ZI.tag node = Some "implementation" then (
    let archive = ZI.make (node.doc) "archive" in
    archive.attrs <- [
      (("", "size"), "100");
      (("", "href"), "http://example.com/download.tgz");
    ];
    node.child_nodes <- archive :: node.child_nodes
  ) else (
    List.iter make_all_downloable node.child_nodes
  )

(** Parse a test-case in solves.xml *)
let make_solver_test test_elem =
  ZI.check_tag "test" test_elem;
  let name = ZI.get_attribute "name" test_elem in
  name >:: (fun () ->
    let (config, fake_system) = Fake_system.get_fake_config None in
    if on_windows then (
      fake_system#add_dir "C:\\Users\\test\\AppData\\Local\\0install.net\\implementations" [];
      fake_system#add_dir "C:\\ProgramData\\0install.net\\implementations" [];
    ) else (
      fake_system#add_dir "/home/testuser/.cache/0install.net/implementations" [];
      fake_system#add_dir "/var/cache/0install.net/implementations" [];
    );
    let reqs = ref (Zeroinstall.Requirements.default_requirements "") in
    let ifaces = Hashtbl.create 10 in
    let fails = ref false in
    let add_iface elem =
      let open Zeroinstall.Feed in
      make_all_downloable elem;
      let uri = ZI.get_attribute "uri" elem in
      let feed = parse (fake_system :> system) elem None in
      Hashtbl.add ifaces uri feed in
    let expected_selections = ref (ZI.make_root "missing") in
    let expected_problem = ref "missing" in
    let justifications = ref [] in
    let process child = match ZI.tag child with
    | Some "interface" -> add_iface child
    | Some "requirements" ->
        reqs := {!reqs with
          Requirements.interface_uri = ZI.get_attribute "interface" child;
          Requirements.command = ZI.get_attribute_opt "command" child;
        };
        fails := ZI.get_attribute_opt "fails" child = Some "true"
    | Some "selections" -> expected_selections := child
    | Some "problem" -> expected_problem := trim child.Support.Qdom.last_text_inside
    | Some "justification" -> justifications := child :: !justifications
    | _ -> failwith "Unexpected element" in
    ZI.iter ~f:process test_elem;

    let feed_provider =
      object (_ : #Feed_cache.feed_provider)
        method get_feed url =
          try
            let overrides = {Feed.last_checked = None; Feed.user_stability = StringMap.empty} in
            Some (Hashtbl.find ifaces url, overrides)
          with Not_found -> None

        method get_distro_impls _feed = None

        method get_iface_config _uri =
          {Feed_cache.stability_policy = None; Feed_cache.extra_feeds = [];}

        method get_feeds_used () = []

        method have_stale_feeds () = false
      end in
    let (ready, result) = Zeroinstall.Solver.solve_for config feed_provider !reqs in
    if ready && !fails then assert_failure "Expected solve to fail, but it didn't!";
    if not ready && not (!fails) then assert_failure "Solve failed (not ready)";
    assert (ready = (not !fails));

    if (!fails) then
      let reason = Zeroinstall.Diagnostics.get_failure_reason config result in
      Fake_system.assert_str_equal !expected_problem reason
    else (
      let actual_sels = result#get_selections in
      assert (ZI.tag actual_sels = Some "selections");
      if ready then (
        let changed = Whatchanged.show_changes (fake_system :> system) !expected_selections actual_sels in
        assert (not changed);
      );
      xml_diff !expected_selections actual_sels
    );

    ListLabels.iter !justifications ~f:(fun elem ->
      let iface = ZI.get_attribute "interface" elem in
      let g_id = Feed.({
        feed = iface;
        id = ZI.get_attribute "id" elem;
      }) in
      let reason = Zeroinstall.Diagnostics.justify_decision config feed_provider !reqs iface g_id in
      Fake_system.assert_str_equal (trim elem.Support.Qdom.last_text_inside) reason
    );
  )

let suite = "solver">::: [
  "sat_simple">:: (fun () ->
    let problem = create () in

    let p1 = add_variable problem "p1" in
    let p2 = add_variable problem "p2" in

    let lib1 = add_variable problem "lib1" in
    let lib2 = add_variable problem "lib2" in

    let decider () = Some p1 in

    ignore @@ at_most_one problem [p1; p2];
    ignore @@ at_most_one problem [lib1; lib2];

    at_least_one problem [neg p1; lib1];
    at_least_one problem [neg p2; lib2];

    match run_solver problem decider with
    | None -> assert false
    | Some solution ->
        assert (solution p1 = true);
        assert (solution p2 = false);

        assert (solution lib1 = true);
        assert (solution lib2 = false)
  );

  "sat_analyse">:: (fun () ->
    let problem = create () in

    let p1 = add_variable problem "p1" in
    let p2 = add_variable problem "p2" in

    let lib1 = add_variable problem "lib1" in
    let lib2 = add_variable problem "lib2" in

    let conf1 = add_variable problem "conf1" in

    let decider () = Some p1 in

    at_least_one problem [p1; p2];
    ignore @@ at_most_one problem [p1; p2];
    ignore @@ at_most_one problem [lib1; lib2];

    (* p1 requires lib1 or lib2 *)
    at_least_one problem [neg p1; lib1; lib2];
    at_least_one problem [neg p2; lib1];

    (* p1 requires conf1, which conflicts with lib1 and lib2 *)
    at_least_one problem [neg p1; conf1];
    at_least_one problem [neg conf1; neg lib1];
    at_least_one problem [neg conf1; neg lib2];

    (* We try p1 first. That requires (lib1 or lib2) and conf1.
      conf1 conflicts with lib, causing us to analyse the problem
      and backtrack. *)

    match run_solver problem decider with
    | None -> assert false
    | Some solution ->
        assert (solution p1 = false);
        assert (solution p2 = true);

        assert (solution lib1 = true);
        assert (solution lib2 = false);
  );

  "sat_at_most">:: (fun () ->
    let problem = create () in

    let p1 = add_variable problem "p1" in
    let p2 = add_variable problem "p2" in

    ignore @@ at_most_one problem [neg p1; neg p2];

    let decider () = Some (neg p1) in
    match run_solver problem decider with
    | None -> assert false
    | Some solution ->
        assert (solution p1 = false);
        assert (solution p2 = true);
  );

  "feed_provider">:: (fun () ->
    let open Feed_cache in
    let (config, fake_system) = Fake_system.get_fake_config None in
    let slave = new Zeroinstall.Python.slave config in
    let distro = new Distro.generic_distribution slave in
    let feed_provider = new feed_provider config distro in
    let uri = "http://example.com/prog" in
    let iface_config = feed_provider#get_iface_config uri in
    assert (iface_config.stability_policy = None);
    assert (iface_config.extra_feeds = []);

    skip_if (Sys.os_type = "Win32") "No native packages";

    fake_system#add_file "/usr/share/0install.net/native_feeds/http:##example.com#prog" "Hello.xml";
    let iface_config = feed_provider#get_iface_config uri in
    assert (iface_config.stability_policy = None);
    match iface_config.extra_feeds with
    | [ { Feed.feed_src = "/usr/share/0install.net/native_feeds/http:##example.com#prog";
          Feed.feed_type = Feed.Distro_packages; _ } ] -> ()
    | [ { Feed.feed_src;_ } ] -> assert_failure feed_src;
    | _ -> assert_failure "Didn't find native feed"
  );

  "impl_provider">:: (fun () ->
    let open Zeroinstall.Impl_provider in
    let (config, fake_system) = Fake_system.get_fake_config None in
    if on_windows then (
      fake_system#add_dir "C:\\Users\\test\\AppData\\Local\\0install.net\\implementations" [];
      fake_system#add_dir "C:\\ProgramData\\0install.net\\implementations" ["sha1=1"];
    ) else (
      fake_system#add_dir "/home/testuser/.cache/0install.net/implementations" [];
      fake_system#add_dir "/var/cache/0install.net/implementations" ["sha1=1"];
    );
    let system = (fake_system :> system) in
    let iface = "http://example.com/prog.xml" in
    let slave = new Zeroinstall.Python.slave config in

    let distro =
      object
        inherit Distro.generic_distribution slave as super
        method! get_package_impls (elem, props) = [
          super#make_package_implementation elem props
            ~is_installed:true
            ~id:"package:is_distro_v1-1"
            ~machine:"x86_64"
            ~version:"1-1"
            ~extra_attrs:[];
          super#make_package_implementation elem props
            ~is_installed:false
            ~id:"package:root_install_needed_2"
            ~machine:"x86_64"
            ~version:"1-1"
            ~extra_attrs:[];
          super#make_package_implementation elem props
            ~is_installed:false
            ~id:"package:root_install_needed_1"
            ~machine:"x86_64"
            ~version:"1-1"
            ~extra_attrs:[];
          super#make_package_implementation elem props
            ~is_installed:true
            ~id:"package:buggy"
            ~machine:"x86_64"
            ~version:"1-1"
            ~extra_attrs:[];
          ]
      end in

    let feed_provider =
      let ifaces = Hashtbl.create 10 in
      let add_iface elem =
        let open Feed in
        let uri = ZI.get_attribute "uri" elem in
        let feed = parse system elem None in
        Hashtbl.add ifaces uri feed in

      add_iface (Support.Qdom.parse_file Fake_system.real_system "ranking.xml");

      object (_ : #Feed_cache.feed_provider)
        method get_feed url =
          try
            let overrides = {
              Feed.last_checked = None;
              Feed.user_stability = StringMap.singleton "preferred_by_user" Preferred;
            } in
            Some (Hashtbl.find ifaces url, overrides)
          with Not_found -> None

        method get_distro_impls feed =
          match Distro.get_package_impls distro feed with
          | Some impls ->
            let overrides = {
              Feed.last_checked = None;
              Feed.user_stability = StringMap.singleton "package:buggy" Buggy;
            } in
            Some (impls, overrides)
          | None -> None

        method get_iface_config _uri =
          {Feed_cache.stability_policy = None; Feed_cache.extra_feeds = [];}

        method get_feeds_used () = []

        method have_stale_feeds () = false
      end in

    config.network_use <- Minimal_network;

    let scope_filter = {
      extra_restrictions = StringMap.empty;
      os_ranks = Arch.get_os_ranks "Linux";
      machine_ranks = Arch.get_machine_ranks "x86_64" ~multiarch:true;
      languages = Support.Utils.filter_map ~f:Support.Locale.parse_lang ["es_ES"; "fr_FR"];
    } in

    let test_solve scope_filter =
      let impl_provider = new default_impl_provider config feed_provider in
      let {replacement; impls; rejects = _} = impl_provider#get_implementations scope_filter iface ~source:false in
      (* List.iter (fun (impl, r) -> failwith @@ describe_problem impl r) rejects; *)
      assert_equal ~msg:"replacement" (Some "http://example.com/replacement.xml") replacement;
      let ids = List.map (fun i -> Feed.get_attr "id" i) impls in
      ids in

    Fake_system.equal_str_lists [
      "preferred_by_user";
      "language_and_country";
      "language_understood";

      "is_stable";
      "package:is_distro_v1-1";

      "is_v1-2";
      "is_v1";

      "poor_machine";
      "poor_os";

      "is_testing";
      "is_dev";
      "not_available_offline";

      "package:root_install_needed_2";
      "package:root_install_needed_1";
    ] (test_solve scope_filter);

    (* Now try in offline mode *)
    config.network_use <- Offline;

    Fake_system.equal_str_lists [
      "preferred_by_user";
      "language_and_country";
      "language_understood";

      "is_stable";
      "package:is_distro_v1-1";

      "is_v1-2";
      "is_v1";

      "poor_machine";
      "poor_os";

      "is_testing";
      "is_dev";
    ] (test_solve scope_filter);
  );

  "solver">:::
    try
      let root = Support.Qdom.parse_file Fake_system.real_system "solves.xml" in
      List.map make_solver_test root.Support.Qdom.child_nodes
    with Safe_exception _ as ex ->
      match Support.Utils.safe_to_string ex with
      | Some msg -> failwith msg
      | None -> assert false
]
