(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(* A dummy PackageKit for unit-tests *)

open Support
open Support.Common
module U = Support.Utils

module D = Zeroinstall.Dbus

open D.OBus_object

let start version : (unit -> unit) Lwt.t =
  D.OBus_bus.system () >>= fun bus ->

  D.OBus_bus.request_name bus "org.freedesktop.PackageKit" >>= fun _ ->

  let impl_m_CreateTransaction _obj () = Lwt.return (D.OBus_path.of_string "/100") in
  let impl_m_GetTid _obj () = Lwt.return "/100" in

  let impl_p_VersionMajor = (fun _ -> Lwt_react.S.const (Int32.of_int version.(0))) in
  let impl_p_VersionMinor = (fun _ -> Lwt_react.S.const (Int32.of_int version.(1))) in
  let impl_p_VersionMicro = (fun _ -> Lwt_react.S.const (Int32.of_int version.(2))) in
  let impl_p_Percentage, set_percentage = Lwt_react.S.create Int32.zero in

  let interface_service =
    let open Zeroinstall.Packagekit_interfaces.Org_freedesktop_PackageKit in

    D.OBus_object.make_interface_unsafe interface
      [
      ]
      [|
        (if version >= [| 0; 8; 1 |] then
          method_info m_CreateTransaction impl_m_CreateTransaction
        else
          method_info m_GetTid impl_m_GetTid);
      |]
      [|
      |]
      [|
        property_r_info p_VersionMajor impl_p_VersionMajor;
        property_r_info p_VersionMicro impl_p_VersionMicro;
        property_r_info p_VersionMinor impl_p_VersionMinor;
      |] in

    let impl_m_SetHints = (fun _obj hints -> log_debug "hints=%s" (List.hd hints); Lwt.return ()) in
    let impl_m_SetLocale = (fun _obj locale -> log_debug "locale=%s" locale; Lwt.return ()) in

  let interface_trans =
    let open Zeroinstall.Packagekit_interfaces.Org_freedesktop_PackageKit_Transaction in

    let impl_m_InstallPackages obj ((_:bool), x) = match x with
      | ["gnupg;2.0.22;x86_64;arch"] ->
          log_info "Installing package...";
          begin
            if version >= [| 0; 8; 1 |] then
              D.OBus_signal.emit s_Package2 obj (Int32.of_int 12, "gnupg;2.0.22;x86_64;arch", "summary")
            else
              D.OBus_signal.emit s_Package1 obj ("installing", "gnupg;2.0.22;x86_64;arch", "summary")
          end >>= fun () ->
          set_percentage (Int32.of_int 1);
          Lwt.pause () >>= fun () ->
          set_percentage (Int32.of_int 50);
          Lwt.pause () >>= fun () ->
          set_percentage (Int32.of_int 100);
          Lwt.pause () >>= fun () ->
          if version >= [| 0; 8; 1 |] then (
            D.OBus_signal.emit s_Package2 obj (Int32.of_int 18, "gnupg;2.0.22;x86_64;arch", "summary") >>= fun () ->
            D.OBus_signal.emit s_Finished2 obj (Int32.of_int 1, Int32.of_int 5)
          ) else (
            D.OBus_signal.emit s_Package1 obj ("finished", "gnupg;2.0.22;x86_64;arch", "summary") >>= fun () ->
            D.OBus_signal.emit s_Finished1 obj ("success", Int32.of_int 5)
          )
      | _-> assert false in

    let impl_m_InstallPackages2 obj ((_:Int64.t), x) = impl_m_InstallPackages obj (false, x) in

    let impl_m_Resolve obj (flags, package_names) =
      assert (flags = "none");
      let status = ref "success" in
      package_names |> Lwt_list.iter_s (function
        | "gnupg" ->
            if version >= [| 0;8;1 |] then
              D.OBus_signal.emit s_Package2 obj (Int32.of_int 2, "gnupg;2.0.22;x86_64;arch", "my summary")
            else
              D.OBus_signal.emit s_Package1 obj ("available", "gnupg;2.0.22;x86_64;arch", "my summary")
        | id ->
            status := "failed";
            if version >= [| 0;8;1 |] then
              D.OBus_signal.emit s_ErrorCode2 obj (Int32.of_int 11, Printf.sprintf "Package name %s could not be resolved" id)
            else
              D.OBus_signal.emit s_ErrorCode obj ("package-not-found", Printf.sprintf "Package name %s could not be resolved" id)
      ) >>= fun () ->
      let runtime = Int32.of_int 5 in
      if version >= [| 0;8;1 |] then (
        let status =
          match !status with
          | "success" -> 1
          | "failed" -> 2
          | _ -> assert false in
        D.OBus_signal.emit s_Finished2 obj (Int32.of_int status, runtime)
      ) else (
        D.OBus_signal.emit s_Finished1 obj (!status, runtime)
      ) in

    let impl_m_Resolve2 obj (flags, package_names) =
      assert (flags = Int64.zero);
      impl_m_Resolve obj ("none", package_names) in

    let impl_m_GetDetails obj package_ids =
      package_ids |> Lwt_list.iter_s (function
        | "gnupg;2.0.22;x86_64;arch" ->
            if version >= [| 0;8;1 |] then
              D.OBus_signal.emit s_Details2 obj ("gnupg;2.0.22;x86_64;arch", "License", Int32.zero, "detail", "http://foo", Int64.of_int 100)
            else
              D.OBus_signal.emit s_Details1 obj ("gnupg;2.0.22;x86_64;arch", "License", "Category", "detail", "http://foo", Int64.of_int 100)
        | id -> Safe_exn.failf "Bad ID '%s'" id
      ) >>= fun () ->
      let runtime = Int32.of_int 5 in
      if version >= [| 0;8;1 |] then (
        D.OBus_signal.emit s_Finished2 obj (Int32.one, runtime)
      ) else (
        D.OBus_signal.emit s_Finished1 obj ("success", runtime)
      ) in

    D.OBus_object.make_interface_unsafe interface
      [
      ]
      [|  (* (must be sorted) *)
        method_info m_GetDetails impl_m_GetDetails;
        (if version >= [| 0; 8; 1 |] then
          method_info m_InstallPackages2 impl_m_InstallPackages2
        else
          method_info m_InstallPackages impl_m_InstallPackages
        );
        (if version >= [| 0; 8; 1 |] then
          method_info m_Resolve2 impl_m_Resolve2
        else
          method_info m_Resolve impl_m_Resolve);
        (if version >= [| 0; 6; 0 |] then
          method_info m_SetHints impl_m_SetHints
        else
          method_info m_SetLocale impl_m_SetLocale);
      |]
      (if version >= [| 0; 8; 1 |] then [|
        signal_info s_ErrorCode2;
        signal_info s_Finished2;
        signal_info s_Package2;
        signal_info s_Details2;
      |] else [|
        signal_info s_ErrorCode;
        signal_info s_Finished1;
        signal_info s_Package1;
        signal_info s_Details1;
      |])
      [|
        property_r_info p_Percentage (fun _ -> impl_p_Percentage);
      |] in

  (* Create the objects *)
  let obj = D.OBus_object.make ~interfaces:[interface_service] ["org"; "freedesktop"; "PackageKit"] in

  let obj_trans = D.OBus_object.make ~interfaces:[interface_trans] ["100"] in

  (* Attach the data *)
  let () = D.OBus_object.attach obj () in
  let () = D.OBus_object.attach obj_trans () in

  (* Export the object on the connection *)
  let () = D.OBus_object.export bus obj in
  let () = D.OBus_object.export bus obj_trans in

  Lwt.return (fun () ->
    let () = remove bus obj in
    remove bus obj_trans)
