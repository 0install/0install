(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

open Zeroinstall.General
open Support.Common
open OUnit
open Zeroinstall

module Q = Support.Qdom
module U = Support.Utils

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

module ListString = OUnitDiff.ListSimpleMake(EString)

let cache_path_for config url = Feed_cache.get_save_cache_path config (`Remote_feed url)

let binary iface = {Selections.iface; source = false}

let set_of_attrs elem : string list =
  let attrs = ref [] in
  elem.Q.attrs |> Q.AttrMap.iter_values (fun (ns, name) value ->
    match ns with
    | "" -> attrs := Printf.sprintf "%s=%s" name value :: !attrs
    | ns -> attrs := Printf.sprintf "{%s}%s=%s" ns name value :: !attrs
  );
  List.sort compare !attrs

let rec fixup_for_windows elem =
  let attrs = elem.Q.attrs |> Q.AttrMap.map (fun value ->
    if U.starts_with value "/root/" then "c:\\root\\" ^ U.string_tail value 6
    else if value = "/root" then "c:\\root"
    else value
  ) in {elem with Q.
    attrs;
    child_nodes = elem.Q.child_nodes |> List.map fixup_for_windows;
  }

let xml_diff exp actual =
  let open Support.Qdom in
  let p = Printf.printf in
  let rec find_diff a b =
    if snd a.tag <> snd b.tag then (
      p "Tag <%s> vs <%s>\n" (snd a.tag) (snd b.tag); true
    ) else if a.tag <> b.tag then (
      p "Namespace '%s' vs '%s'\n" (fst a.tag) (fst a.tag); true
    ) else (
      assert_equal ~printer:(fun s -> s) (String.trim a.text_before) (String.trim b.text_before);
      assert_equal ~printer:(fun s -> s) (String.trim a.last_text_inside) (String.trim b.last_text_inside);
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
      (to_utf8 (Q.reindent actual))
  ) else assert (compare_nodes ~ignore_whitespace:true exp actual = 0)

let make_impl_provider config scope_filter =
  let distro = Fake_distro.make config in
  let feed_provider = new Feed_provider_impl.feed_provider config distro in
  let impl_provider = new Impl_provider.default_impl_provider config (feed_provider :> Feed_provider.feed_provider) scope_filter in
  (impl_provider :> Impl_provider.impl_provider)

(** Give every implementation an <archive>, so we think it's installable. *)
let rec make_all_downloable node =
  let open Support.Qdom in
  if ZI.tag node = Some "implementation" then (
    let attrs = Q.AttrMap.empty
      |> Q.AttrMap.add_no_ns "size" "100"
      |> Q.AttrMap.add_no_ns "href" "http://example.com/download.tgz" in
    let archive = ZI.make ~attrs "archive" in
    {node with child_nodes = archive :: node.child_nodes}
  ) else (
    {node with child_nodes = List.map make_all_downloable node.child_nodes}
  )

let linux_multi_scope_filter = { Scope_filter.
  extra_restrictions = StringMap.empty;
  os_ranks = Arch.get_os_ranks Arch.linux;
  machine_ranks = Arch.get_machine_ranks Arch.x86_64 ~multiarch:true;
  languages = Support.Locale.LangMap.empty;
  allowed_uses = StringSet.empty;
  may_compile = false;
}

class fake_feed_provider system (distro:Distro.provider option) =
  let ifaces = Hashtbl.create 10 in

  object (_ : #Feed_provider.feed_provider)
    method get_feed url =
      try
        let overrides = {
          Feed.last_checked = None;
          Feed.user_stability = StringMap.empty;
        } in
        Some (Hashtbl.find ifaces url, overrides)
      with Not_found -> None

    method replace_feed url feed =
      Hashtbl.add ifaces url feed

    method get_distro_impls feed =
      let overrides = {
        Feed.last_checked = None;
        Feed.user_stability = StringMap.empty;
      } in
      match distro with
      | None -> {Feed_provider.impls = StringMap.empty; overrides; problems = []}
      | Some distro ->
          let impls = distro#get_impls_for_feed ~problem:failwith feed in
          {Feed_provider.impls; overrides; problems = []}

    method get_iface_config _uri =
      {Feed_cache.stability_policy = None; Feed_cache.extra_feeds = [];}

    method get_feeds_used = []

    method have_stale_feeds = false

    method was_used = failwith "was_used"

    method add_iface elem =
      let open Feed in
      let (feed, uri) =
        match ZI.get_attribute_opt "uri" elem with
        | Some url -> (parse system (Element.parse_feed elem) None, url)
        | None ->
            let name = ZI.get_attribute "local-path" elem in
            let path = U.abspath system name in
            (parse system (Element.parse_feed elem) (Some path), path) in
      Hashtbl.add ifaces (Zeroinstall.Feed_url.master_feed_of_iface uri) feed

    method forget_distro _ = failwith "forget_distro"
    method forget_user_feeds _ = failwith "forget_user_feeds"
  end

(** Parse a test-case in solves.xml *)
let make_solver_test test_elem =
  ZI.check_tag "test" test_elem;
  let name = ZI.get_attribute "name" test_elem in
  let add_downloads = ZI.get_attribute_opt "add-downloads" test_elem = Some "true" in
  name >:: (fun () ->
    let (config, fake_system) = Fake_system.get_fake_config None in
    if on_windows then (
      fake_system#add_dir "C:\\Users\\test\\AppData\\Local\\0install.net\\implementations" [];
      fake_system#add_dir "C:\\ProgramData\\0install.net\\implementations" [];
    ) else (
      fake_system#add_dir "/home/testuser/.cache/0install.net/implementations" [];
      fake_system#add_dir "/var/cache/0install.net/implementations" [];
    );
    fake_system#add_dir fake_system#getcwd [];
    let system = (fake_system :> system) in
    let reqs = ref (Zeroinstall.Requirements.run "") in
    let fails = ref false in
    let expected_selections = ref (ZI.make "missing") in
    let expected_problem = ref "missing" in
    let justifications = ref [] in
    let feed_provider = new fake_feed_provider system None in
    let process child = match ZI.tag child with
    | Some "suppress-warnings" ->
        Fake_system.forward_to_real_log := false;
    | Some "interface" ->
        let child = if add_downloads then make_all_downloable child else child in
        feed_provider#add_iface child
    | Some "import-interface" ->
        let leaf = ZI.get_attribute "from-python" child in
        let root = Support.Qdom.parse_file system @@ Test_0install.feed_dir +/ leaf in
        let fix_path attrs =
          if ZI.get_attribute_opt "uri" root = None then (
            attrs |> Q.AttrMap.add_no_ns "local-path" ("./" ^ leaf)
          ) else attrs in
        feed_provider#add_iface {root with Q.attrs = fix_path root.Q.attrs}
    | Some "requirements" ->
        let iface = ZI.get_attribute "interface" child in
        let iface =
          if U.starts_with iface "./" then U.abspath (fake_system :> system) iface
          else iface in
        reqs := {!reqs with Requirements.
          interface_uri = iface;
          command = ZI.get_attribute_opt "command" child;
          source = ZI.get_attribute_opt "source" child = Some "true";
          may_compile = ZI.get_attribute_opt "may-compile" child = Some "true";
          os = ZI.get_attribute_opt "os" child |> pipe_some Arch.parse_os;
        };
        child |> ZI.iter ~name:"restricts" (fun restricts ->
          let iface = ZI.get_attribute "interface" restricts in
          let expr = ZI.get_attribute "version" restricts in
          reqs := {!reqs with
            Requirements.extra_restrictions = StringMap.add iface expr !reqs.Requirements.extra_restrictions
          }
        );
        fails := ZI.get_attribute_opt "fails" child = Some "true"
    | Some "selections" -> expected_selections := child
    | Some "problem" -> expected_problem := String.trim child.Support.Qdom.last_text_inside
    | Some "justification" -> justifications := child :: !justifications
    | _ -> Support.Qdom.raise_elem "Unexpected element" child in
    ZI.iter process test_elem;

    (* To test the ... part, we can't log at debug level. *)
    Support.Logging.threshold := Support.Logging.Info;

    let (ready, result) = Zeroinstall.Solver.solve_for config (feed_provider :> Feed_provider.feed_provider) !reqs in
    if ready && !fails then assert_failure "Expected solve to fail, but it didn't!";
    if not ready && not (!fails) then (
      let reason = Zeroinstall.Solver.get_failure_reason config result in
      assert_failure ("Solve failed (not ready)\n" ^ reason)
    );
    assert (ready = (not !fails));

    if (!fails) then
      let reason = Zeroinstall.Solver.get_failure_reason config result in
      Fake_system.assert_str_equal !expected_problem (Test_driver.fixup_windows_paths reason)
    else (
      let actual_sels = Solver.selections result in
      (* Selections.as_xml actual_sels |> Q.reindent |> Q.to_utf8 |> print_endline; *)
      assert (ZI.tag (Selections.as_xml actual_sels) = Some "selections");
      if ready then (
        let changed = Whatchanged.show_changes (fake_system :> system) (Some (Selections.create !expected_selections)) actual_sels in
        if changed then
          let sels = Selections.as_xml actual_sels |> Q.reindent |> Q.to_utf8 in
          assert_failure (Printf.sprintf "Ready, but not as expected. Got:\n" ^ sels)
      );
      xml_diff !expected_selections (Selections.as_xml actual_sels)
    );

    ListLabels.iter !justifications ~f:(fun elem ->
      let iface = ZI.get_attribute "interface" elem in
      let g_id = Feed_url.({
        feed = Feed_url.parse iface;
        id = ZI.get_attribute "id" elem;
      }) in
      let reason = Zeroinstall.Justify.justify_decision config (feed_provider :> Feed_provider.feed_provider) !reqs iface ~source:false g_id in
      Fake_system.assert_str_equal (String.trim elem.Support.Qdom.last_text_inside) reason
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
    let distro = Fake_distro.make config in
    let feed_provider = new Feed_provider_impl.feed_provider config distro in
    let uri = "http://example.com/prog" in
    let iface_config = feed_provider#get_iface_config uri in
    assert (iface_config.stability_policy = None);
    assert (iface_config.extra_feeds = []);

    skip_if (Sys.os_type = "Win32") "No native packages";

    fake_system#add_file "/usr/share/0install.net/native_feeds/http:##example.com#prog" "Hello.xml";
    let iface_config = feed_provider#get_iface_config uri in
    assert (iface_config.stability_policy = None);
    match iface_config.extra_feeds with
    | [ { Feed.feed_src = `Local_feed "/usr/share/0install.net/native_feeds/http:##example.com#prog";
          Feed.feed_type = Feed.Distro_packages; _ } ] -> ()
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

    let distro =
      object (self : Distro.distribution)
        inherit Distro.distribution config
        val id_prefix = "package:dummy"
        val distro_name = "dummy"
        val check_host_python = false
        method! private is_installed = failwith "is_installed"
        method check_for_candidates = raise_safe "Unexpected check_for_candidates"
        method! install_distro_packages = raise_safe "install_distro_packages"
        method private get_package_impls query =
          let machine = Some Arch.x86_64 in
          self#add_package_implementation
            ~package_state:`Installed
            ~id:"package:is_distro_v1-1"
            ~machine
            ~version:(Version.parse "1-1")
            ~quick_test:None
            ~distro_name
            query;
          self#add_package_implementation
            ~package_state:(`Uninstalled Impl.({distro_size = None; distro_install_info = ("dummy", "root_install_needed_2")}))
            ~id:"package:root_install_needed_2"
            ~machine
            ~version:(Version.parse "1-1")
            ~quick_test:None
            ~distro_name
            query;
          self#add_package_implementation
            ~package_state:(`Uninstalled Impl.({distro_size = None; distro_install_info = ("dummy", "root_install_needed_1")}))
            ~id:"package:root_install_needed_1"
            ~machine
            ~version:(Version.parse "1-1")
            ~quick_test:None
            ~distro_name
            query;
          self#add_package_implementation
            ~package_state:`Installed
            ~id:"package:buggy"
            ~machine
            ~version:(Version.parse "1-1")
            ~quick_test:None
            ~distro_name
            query;
      end in

    let feed_provider =
      object
        inherit fake_feed_provider system (Some distro) as super

        method! get_feed url =
          match super#get_feed url with
          | None -> None
          | Some (feed, overrides) ->
              let overrides = {overrides with Feed.user_stability = StringMap.singleton "preferred_by_user" Stability.Preferred} in
              Some (feed, overrides)

        method! get_distro_impls feed =
          let result = super#get_distro_impls feed in
          let overrides = {result.Feed_provider.overrides with Feed.user_stability = StringMap.singleton "package:buggy" Stability.Buggy} in
          {result with Feed_provider.overrides}
      end in
    feed_provider#add_iface (Support.Qdom.parse_file Fake_system.real_system (Fake_system.tests_dir +/ "ranking.xml"));
    config.network_use <- Minimal_network;

    let scope_filter = { linux_multi_scope_filter with Scope_filter.
      languages = Support.Locale.score_langs @@ U.filter_map Support.Locale.parse_lang ["es_ES"; "fr_FR"];
    } in

    let test_solve scope_filter =
      let impl_provider = new default_impl_provider config (feed_provider :> Feed_provider.feed_provider) scope_filter in
      let {replacement; impls; _} = impl_provider#get_implementations iface ~source:false in
      (* List.iter (fun (impl, r) -> failwith @@ describe_problem impl r) rejects; *)
      assert_equal ~msg:"replacement" (Some "http://example.com/replacement.xml") replacement;
      let ids = List.map (fun i -> Impl.get_attr_ex "id" i) impls in
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

  "ranking2">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in

    let impl_provider = make_impl_provider config linux_multi_scope_filter in

    let iface = Test_0install.feed_dir +/ "Ranking.xml" in

    let test_solve =
      let impls = (impl_provider#get_implementations iface ~source:false).Impl_provider.impls in
      let ids = List.map (fun i -> (Impl.get_attr_ex "version" i) ^ " " ^ (Impl.get_attr_ex "arch" i)) impls in
      ids in

    Fake_system.equal_str_lists [
      "0.2 Linux-i386";         (* poor arch, but newest version *)
      "0.1 Linux-x86_64";       (* 64-bit is best match for host arch *)
      "0.1 Linux-i686"; "0.1 Linux-i586"; "0.1 Linux-i486"]	(* ordering of x86 versions *)
      test_solve;
  );

  "details">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let import name =
      U.copy_file config.system (Test_0install.feed_dir +/ name) (cache_path_for config @@ "http://foo/" ^ name) 0o644 in
    let iface = "http://foo/Binary.xml" in
    import "Binary.xml";
    import "Compiler.xml";
    import "Source.xml";

    let distro = Fake_distro.make config in
    let feed_provider = new Feed_provider_impl.feed_provider config distro in

    let impl_provider = new Impl_provider.default_impl_provider config (feed_provider :> Feed_provider.feed_provider) linux_multi_scope_filter in
    let bin_impls = impl_provider#get_implementations iface ~source:true in
    let () =
      match bin_impls.Impl_provider.rejects with
      | [(impl, reason)] ->
          Fake_system.assert_str_equal "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a" (Impl.get_attr_ex "id" impl);
          Fake_system.assert_str_equal "We want source and this is a binary" (Impl_provider.describe_problem impl reason);
      | _ -> assert false in
    let comp_impls = impl_provider#get_implementations "http://foo/Compiler.xml" ~source:false in

    assert_equal 0 (List.length comp_impls.Impl_provider.rejects);
    assert_equal 3 (List.length comp_impls.Impl_provider.impls);

    let reqs = Requirements.({
      (run iface) with
      source = true;
      command = Some "compile"}) in

    let justify expected iface ~source feed id =
      let g_id = Feed_url.({feed; id}) in
      let actual = Justify.justify_decision config (feed_provider :> Feed_provider.feed_provider) reqs iface ~source g_id in
      Fake_system.assert_str_equal expected actual in

    justify
      "http://foo/Binary.xml 1.0 cannot be used (regardless of other components): We want source and this is a binary"
      iface ~source:true (Feed_url.master_feed_of_iface iface) "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a";
    justify
      "http://foo/Binary.xml 1.0 was selected as the preferred version."
      iface ~source:true (`Remote_feed "http://foo/Source.xml") "sha1=3ce644dc725f1d21cfcf02562c76f375944b266a";
    justify
      "0.1 is ranked lower than 1.0: newer versions are preferred"
      iface ~source:true (`Remote_feed "http://foo/Source.xml") "old";
    justify
      ("There is no possible selection using http://foo/Binary.xml 3.\n" ^
      "Can't find all required implementations:\n" ^
      "- http://foo/Binary.xml#source -> 3 (impossible)\n" ^
      "- http://foo/Compiler.xml -> (problem)\n" ^
      "    http://foo/Binary.xml#source 3 requires version ..!1.0, version 1.0..\n" ^
      "    Rejected candidates:\n" ^
      "      sha1=999 (5): Incompatible with restriction: version ..!1.0\n" ^
      "      sha1=345 (1.0): Incompatible with restriction: version ..!1.0\n" ^
      "      sha1=678 (0.1): Incompatible with restriction: version 1.0..")
      iface ~source:true (`Remote_feed "http://foo/Source.xml") "impossible";
    justify
      ("http://foo/Compiler.xml 5 is selectable, but using it would produce a less optimal solution overall.\n\n" ^
      "The changes would be:\n\nhttp://foo/Binary.xml#source: 1.0 to 0.1")
      "http://foo/Compiler.xml" ~source:false (`Remote_feed "http://foo/Compiler.xml") "sha1=999";

    import "Recursive.xml";
    let rec_impls = impl_provider#get_implementations "http://foo/Recursive.xml" ~source:false in
    match rec_impls.Impl_provider.impls with
    | [impl] -> Fake_system.assert_str_equal "sha1=abc" (Impl.get_attr_ex "id" impl)
    | _ -> assert false
  );

  "command">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let r = Requirements.run (Test_0install.feed_dir +/ "command-dep.xml") in
    let distro = Fake_distro.make config in
    let feed_provider = new Feed_provider_impl.feed_provider config distro in
    match Solver.solve_for config (feed_provider :> Feed_provider.feed_provider) r with
    | (false, _) -> assert false
    | (true, results) ->
        let sels = Solver.selections results in
        let sel = Zeroinstall.Selections.get_selected_ex (Selections.root_role sels) sels in
        let command = Element.get_command_ex "run" sel in
        match Element.command_children command with
        | [`Requires dep] ->
            let dep_impl = Zeroinstall.Selections.get_selected_ex (binary (Element.interface dep)) sels in
            let command = Element.get_command_ex "run" dep_impl in
            Fake_system.assert_str_equal "test-gui" (Element.path command |> default "missing")
        | _ -> assert false
  );

  "multiarch">::  Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in

    let import name =
      U.copy_file config.system (Test_0install.feed_dir +/ name) (cache_path_for config @@ "http://foo/" ^ name) 0o644 in

    import "MultiArch.xml";
    import "MultiArchLib.xml";

    let check_arch expected machine =
      let machine = Arch.parse_machine machine |> Fake_system.expect in
      let scope_filter = { linux_multi_scope_filter with
        Scope_filter.machine_ranks = Arch.get_machine_ranks machine ~multiarch:true;
      } in
      let impl_provider = make_impl_provider config scope_filter in
      let root_req = { Solver.Model.
        role = {
          Solver.scope = impl_provider;
          iface = "http://foo/MultiArch.xml";
          source = false
        };
        command = None;
      } in
      match Solver.do_solve root_req ~closest_match:false with
      | None -> assert false
      | Some results ->
          let sels = Solver.selections results in
          Zeroinstall.Selections.get_selected_ex (binary "http://foo/MultiArch.xml") sels
          |> Element.arch |> default "missing" |> Fake_system.assert_str_equal expected;
          Zeroinstall.Selections.get_selected_ex (binary "http://foo/MultiArchLib.xml") sels
          |> Element.arch |> default "missing" |> Fake_system.assert_str_equal expected in

    (* On an i686 system we can only use the i486 implementation *)
    check_arch "Linux-i486" "i686";

    (* On an 64 bit system we could use either, but we prefer the 64
     * bit implementation. The i486 version of the library is newer,
     * but we must pick one that is compatible with the main binary. *)
    check_arch "Linux-x86_64" "x86_64";
  );

  "restricts">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let uri = Test_0install.feed_dir +/ "Conflicts.xml" in
    let versions = Test_0install.feed_dir +/ "Versions.xml" in
    let r = Requirements.run uri in

    (* Selects 0.2 as the highest version, applying the restriction to versions < 4. *)
    let distro = Fake_distro.make config in
    let feed_provider = new Feed_provider_impl.feed_provider config distro in

    let do_solve r =
      match Solver.solve_for config feed_provider r with
      | (false, _) -> assert false
      | (true, results) -> Solver.selections results in

    let results = do_solve r in
    Fake_system.assert_str_equal "0.2" @@ Element.version (Zeroinstall.Selections.get_selected_ex (binary uri) results);
    Fake_system.assert_str_equal "3" @@ Element.version (Zeroinstall.Selections.get_selected_ex (binary versions) results);

    let extras = StringMap.singleton uri "0.1" in
    let results = do_solve {r with Requirements.extra_restrictions = extras} in
    Fake_system.assert_str_equal "0.1" @@ Element.version (Zeroinstall.Selections.get_selected_ex (binary uri) results);
    assert (Zeroinstall.Selections.get_selected (binary versions) results = None);

    let extras = StringMap.singleton uri "0.3" in
    let r = {r with Requirements.extra_restrictions = extras} in
    assert_equal false (fst @@ Solver.solve_for config feed_provider r);
  );

  "langs">:: Fake_system.with_tmpdir (fun tmpdir ->
    let (config, _fake_system) = Fake_system.get_fake_config (Some tmpdir) in
    let distro = Fake_distro.make config in
    let feed_provider = new Feed_provider_impl.feed_provider config distro in
    let solve expected ?(lang="en_US.UTF-8") machine =
      let machine = Arch.parse_machine machine |> Fake_system.expect in
      let scope_filter = { linux_multi_scope_filter with Scope_filter.
        machine_ranks = Arch.get_machine_ranks machine ~multiarch:true;
        languages = Support.Locale.score_langs [Fake_system.expect @@ Support.Locale.parse_lang lang];
      } in
      let impl_provider = new Impl_provider.default_impl_provider config feed_provider scope_filter in
      let root_req = { Solver.Model.
        role = {
          Solver.scope = impl_provider;
          iface = Test_0install.feed_dir +/ "Langs.xml";
          source = false
        };
        command = None;
      } in
      match Solver.do_solve root_req ~closest_match:false with
      | None -> assert_failure expected
      | Some results ->
          match (Selections.as_xml (Solver.selections results)).Support.Qdom.child_nodes with
          | [sel] -> Fake_system.assert_str_equal expected @@ ZI.get_attribute "id" sel
          | _ -> assert false in

    (* 1 is the oldest, but the only one in our language *)
    solve "sha1=1" "arch_1";

    (* 6 is the newest, and close enough, even though not
     * quite the right locale *)
    solve "sha1=6" "arch_2";

    (* 9 is the newest, although 7 is a closer match *)
    solve "sha1=9" "arch_3";

    (* 11 is the newest we understand *)
    solve "sha1=11" "arch_4";

    (* 13 is the newest we understand *)
    solve "sha1=13" "arch_5";

    (* We don't understand any, so pick the newest *)
    solve "sha1=6" ~lang:"es_ES" "arch_2";

    (* These two have the same version number. Choose the *)
    (* one most appropriate to our country *)
    solve "sha1=15" ~lang:"zh_CN" "arch_6" ;
    solve "sha1=16" ~lang:"zh_TW" "arch_6" ;

    (* Same, but one doesn't have a country code *)
    solve "sha1=17" ~lang:"bn"    "arch_7";
    solve "sha1=18" ~lang:"bn_IN" "arch_7";
  );

  "arch">:: (fun () ->
    let os_ok supported by_host =
      let supported = Arch.parse_os supported in
      let by_host = Arch.parse_os by_host |> Fake_system.expect in
      Arch.os_ok (Arch.get_os_ranks by_host) supported in
    let machine_ok ~multiarch supported by_host =
      let supported = Arch.parse_machine supported in
      let by_host = Arch.parse_machine by_host |> Fake_system.expect in
      Arch.machine_ok (Arch.get_machine_ranks ~multiarch by_host) supported in

    assert (os_ok "Darwin" "MacOSX");
    assert (machine_ok "i386" ~multiarch:true "i686");
    assert (machine_ok "i386" ~multiarch:true "x86_64");
    assert (not (machine_ok "i386" ~multiarch:false "x86_64"));

    assert (os_ok "POSIX" "MacOSX");
    assert (not (os_ok "POSIX" "Windows"));

    assert (os_ok "FooBar" "FooBar");
    assert (machine_ok "i486" ~multiarch:false "i486");
    assert (not (machine_ok "ppc" ~multiarch:false "i486"));
  );

  "solver">:::
    U.handle_exceptions (fun () ->
      let root = Support.Qdom.parse_file Fake_system.real_system "tests/solves.xml" in
      let root = if on_windows then fixup_for_windows root else root in
      List.map make_solver_test root.Support.Qdom.child_nodes
    ) ()
]
