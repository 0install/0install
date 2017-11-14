(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* These tests actually run a dummy web-server. *)

open Zeroinstall.General
open Support.Common
open OUnit

module U = Support.Utils
module Impl = Zeroinstall.Impl
module Distro = Zeroinstall.Distro
module Distro_impls = Zeroinstall.Distro_impls

let assert_str_equal = Fake_system.assert_str_equal
let assert_contains = Fake_system.assert_contains
let expect = Fake_system.expect

let approve_ui =
  object
    inherit Fake_system.null_ui
    method! confirm msg = log_info "confirm: %s -> OK" msg; Lwt.return `Ok
  end

let matches ~regex msg =
  let re = Str.regexp regex in
  Str.string_match re msg 0

let test ?(package="gnupg") ?(expected_problems=[]) config fake_system =
  let expected_problems = ref expected_problems in
  let problem msg =
    match !expected_problems with
    | p::ps when matches ~regex:p msg -> expected_problems := ps
    | p::_ -> assert_failure (Printf.sprintf "Expected:\n%s\nGot:\n%s" p msg)
    | [] -> assert_failure (Printf.sprintf "Unexpected problem: %s" msg) in
  let system = (fake_system :> system) in
  let packagekit = lazy (Zeroinstall.Packagekit.make (Support.Locale.LangMap.choose config.langs |> fst)) in
  let distro = Distro_impls.ArchLinux.arch_distribution ~packagekit config |> Distro.of_provider in
  let feed = Test_feed.feed_of_xml system (Printf.sprintf "\
<interface xmlns='http://zero-install.sourceforge.net/2004/injector/interface' uri='http://example.com/gpg'>\n\
  <name>Gpg</name>\n\
  <package-implementation package='%s'/>\n\
</interface>" package) in
  Distro.check_for_candidates distro ~ui:Fake_system.null_ui feed |> Lwt_main.run;
  log_info "done check_for_candidates";
  let impls = Distro.get_impls_for_feed distro ~problem feed |> Test_distro.to_impl_list in
  impls |> List.iter (function
    | {Impl.impl_type = `Package_impl {Impl.package_state = `Uninstalled rm; _}; _} ->
        assert_equal (Some (Int64.of_int 100)) rm.Impl.distro_size;
    | _ -> assert false
  );
  !expected_problems |> List.iter (fun msg -> assert_failure (Printf.sprintf "Missing expected error: %s" msg));
  assert_equal `Ok (Distro.install_distro_packages distro approve_ui impls |> Lwt_main.run);
  List.length impls

let suite =
  "packagekit">:: Fake_system.with_fake_config (fun (config, fake_system) ->
    let daemon_prog =
      match U.find_in_path config.system "dbus-daemon" with
      | None -> skip_if true "No dbus-daemon"; assert false
      | Some path -> path in

    let dbus_config = Fake_system.tests_dir +/ "dbus.conf" in
    let addr = "unix:tmpdir=" ^ Fake_system.temp_dir_name in
    let dbus_args = [daemon_prog; "--nofork"; "--print-address"; "--address=" ^ addr; "--config-file"; dbus_config] in
    let r, w = Unix.pipe () in
    U.finally_do (fun child -> Unix.kill child Sys.sigkill; Support.System.waitpid_non_intr child |> ignore)
      (Fake_system.real_system#create_process dbus_args Unix.stdin w Unix.stderr)
      (fun _child ->
        Unix.close w;
        let bus_address = input_line (Unix.in_channel_of_descr r) in
        Unix.close r;

        U.finally_do
          (fun () -> Unix.putenv "DBUS_SYSTEM_BUS_ADDRESS" "DBUS_SYSTEM_UNUSED")
          (Unix.putenv "DBUS_SYSTEM_BUS_ADDRESS" bus_address; fake_system#putenv "DBUS_SYSTEM_BUS_ADDRESS" bus_address)
          (fun () ->
(*             Unix.system ("dbus-monitor --address " ^ bus_address ^ " &") |> ignore; *)

            assert_equal 0 @@ test config fake_system
              ~expected_problems:["gnupg: PackageKit not available: .*"];

            let destroy =
              try Lwt_main.run (Pk_service.start [| 0; 8; 1 |])
              with Safe_exception ("No D-BUS!", _) -> skip_if true "No D-BUS support compiled in"; assert false in
            assert_equal 1 @@ test config fake_system;
            Fake_system.fake_log#assert_contains "confirm: The following components need to be installed using native packages.";

            assert_equal 0 @@ test ~package:"foo" ~expected_problems:["'foo' details not in PackageKit response"] config fake_system;

            destroy ();
            Fake_system.fake_log#reset;

            (* Check service has stopped *)
            assert_equal 0 @@ test config fake_system
              ~expected_problems:["gnupg: PackageKit not available: .*"];

            let destroy = Lwt_main.run (Pk_service.start [| 0; 7; 6 |]) in
            assert_equal 1 @@ test config fake_system;
            destroy ();

            let destroy = Lwt_main.run (Pk_service.start [| 0; 5; 1 |]) in
            assert_equal 1 @@ test config fake_system;
            destroy ();
          )
      );
  )
