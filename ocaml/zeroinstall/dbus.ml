(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Convenience functions for D-BUS. This module can be imported even if D-BUS support isn't available. *)

open Support.Common

IFDEF HAVE_DBUS THEN
module OBus_bus = OBus_bus
module OBus_connection = OBus_connection
module Notification = Notification
module Nm_manager = Nm_manager
module OBus_property = OBus_property

let session ?switch () =
  Lwt.catch (fun () ->
    (* Prevent OBus from killing us. *)
    Lwt.bind (OBus_bus.session ?switch ()) (fun session_bus ->
      OBus_connection.set_on_disconnect session_bus (fun ex -> log_info ~ex "D-BUS disconnect"; Lwt.return ());
      Lwt.return (Some session_bus)
    )
  )
  (fun ex ->
    log_debug ~ex "Failed to get D-BUS session bus";
    Lwt.return None
  )

let system () =
  Lwt.catch (fun () ->
      Lwt.bind (OBus_bus.system ()) (fun system_bus -> Lwt.return (Some system_bus))
    )
    (fun ex ->
      log_debug ~ex "Failed to get D-BUS system bus";
      Lwt.return None
    )

ELSE

let session ?switch:_ () = Lwt.return None
let system ?switch:_ () = Lwt.return None

(* Always call [session] first. If you get None, don't use Notification. *)
module Notification =
  struct
    let get_server_information () = raise_safe "No D-BUS"
    let notify ?app_name:_ ?id:_ ?icon:_ ?summary:_ ?body:_ ?actions:_ ?hints:_ ?timeout:_ () = raise_safe "No D-BUS"
  end

(* Always call [system] first. If you get None, don't use Nm_manager. *)
module Nm_manager =
  struct
    let daemon () = raise_safe "No D-Bus"
    type state =
      [ `Unknown
      | `Asleep
      | `Connecting
      | `Connected
      | `Disconnected ]
    let state _daemon : state Lwt.t = raise_safe "No D-Bus"
  end

module OBus_property =
  struct
    let get _prop = raise_safe "No D-Bus"
  end
ENDIF
