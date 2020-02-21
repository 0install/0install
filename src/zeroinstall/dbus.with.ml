(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Convenience functions for D-BUS. This file is only compiled when D-BUS support is available. *)

open Support
open Common

module OBus_bus = OBus_bus
module OBus_proxy = OBus_proxy
module OBus_peer = OBus_peer
module OBus_path = OBus_path
module OBus_member = OBus_member
module OBus_value = OBus_value
module OBus_connection = OBus_connection
module Notification = Notification
module Nm_manager = Nm_manager
module OBus_property = OBus_property
module OBus_method = OBus_method
module OBus_signal = OBus_signal
module OBus_error = OBus_error
module OBus_object = OBus_object

let () =
  (* Don't log a warning if we can't find a bus. *)
  Lwt_log.add_rule "obus(bus)" Lwt_log.Error

let session ?switch () =
  Lwt.catch (fun () ->
    begin try if Sys.getenv "DBUS_SESSION_BUS_ADDRESS" = "DBUS_SESSION_UNUSED" then
      failwith "Disabled for unit-tests"
    with Not_found -> () end;
    (* Prevent OBus from killing us. *)
    OBus_bus.session ?switch () >>= fun session_bus ->
    OBus_connection.set_on_disconnect session_bus (fun ex -> log_info ~ex "D-BUS disconnect"; return ());
    return (`Ok session_bus)
  )
  (fun ex ->
    log_debug ~ex "Failed to get D-BUS session bus";
    return (`Error "Failed to get D-BUS session bus")
  )

let system () =
  Lwt.catch (fun () ->
      begin try if Sys.getenv "DBUS_SYSTEM_BUS_ADDRESS" = "DBUS_SYSTEM_UNUSED" then
        failwith "Disabled for unit-tests"
      with Not_found -> () end;
      OBus_bus.system () >|= fun system_bus -> `Ok system_bus
    )
    (fun ex ->
      log_debug ~ex "Failed to get D-BUS system bus";
      return (`Error "Failed to get D-BUS system bus")
    )

let have_dbus = true
