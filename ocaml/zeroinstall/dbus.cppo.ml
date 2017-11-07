(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Convenience functions for D-BUS. This module can be imported even if D-BUS support isn't available. *)

open Support.Common

#ifdef HAVE_DBUS
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

#else

let session ?switch:_ () =
  return (`Error "0install was compiled without D-BUS support")

let system ?switch:_ () =
  return (`Error "0install was compiled without D-BUS support")

let no_dbus _ = raise_safe "No D-BUS!"

(* Always call [session] first. If you get None, don't use Notification. *)
module Notification =
  struct
    let get_server_information = no_dbus
    let notify ?app_name:_ ?id:_ ?icon:_ ?summary:_ ?body:_ ?actions:_ ?hints:_ ?timeout:_ = no_dbus
  end

(* Always call [system] first. If you get None, don't use Nm_manager. *)
module Nm_manager =
  struct
    let daemon = no_dbus
    type state =
      [ `Unknown
      | `Asleep
      | `Connecting
      | `Connected
      | `Disconnected ]
    let state _daemon : state Lwt.t = no_dbus ()
  end

module OBus_property =
  struct
    let get = no_dbus
    let monitor ?switch:_ = no_dbus
    let make ?monitor:_ _desc = no_dbus
  end

module OBus_bus =
  struct
    exception Service_unknown of string
    let system ?switch:_ = no_dbus
    let request_name _bus = no_dbus
  end

module OBus_object =
  struct
    let make_interface_unsafe _name _annotations _methods _signals = no_dbus
    let method_info _info = no_dbus
    let property_r_info _info _ : unit = no_dbus ()
    let signal_info = no_dbus
    let make ~interfaces:_ = no_dbus
    let attach _obj = no_dbus
    let export _connection = no_dbus
    let remove _connection = no_dbus
  end

module OBus_error =
  struct
    exception Unknown_object of string
  end

module OBus_peer =
  struct
    type t = {
      connection : unit;
      name : unit;
    }
    let make ~connection:_ ~name:_ = no_dbus ()
  end

module OBus_path =
  struct
    type t = string
    let of_string = no_dbus
  end

module OBus_proxy =
  struct
    type t = {
      peer : OBus_peer.t;
      path : OBus_path.t;
    }
    let make ~peer:_ ~path:_ = no_dbus ()
  end

module OBus_value =
  struct
    module C =
      struct
        exception Signature_mismatch
        let array _ = ()
        let dict _ _ = ()
        let string = ()
        let variant = ()
        let cast_single _ = failwith "cast_single"
        let basic_boolean = ()
        let basic_uint32 = ()
        let basic_uint64 = ()
        let basic_string = ()
        let basic_object_path = ()
        type 'a sequence = 'a list
      end

    module V = struct
      let string_of_single _ = ""
    end

    type 'a arguments = unit

    let arg0 = ()
    let arg1 _ = ()
    let arg2 _ _ = ()
    let arg3 _ _ _ = ()
    let arg6 _ _ _ _ _ _ = ()
  end

module OBus_member =
  struct
    module Method =
      struct
        type ('a, 'b) t = {
          interface : string;
          member : string;
          i_args : 'a OBus_value.arguments;
          o_args : 'b OBus_value.arguments;
          annotations : (string * string) list;
        }
      end

    module Property =
      struct
        type ('a, 'access) t = {
          interface : string;
          member : string;
          typ : unit;
          access : unit;
          annotations : (string * string) list;
        }

        let readable = ()
      end

      module Signal =
        struct
          type 'a t = {
            interface : string;
            member : string;
            args : unit;
            annotations : (string * string) list;
        }
        end
  end

module OBus_method =
  struct
    let call _info _proxy = no_dbus
  end

module OBus_signal =
  struct
    let connect ?switch:_ = no_dbus
    let make _signal = no_dbus
    let emit _info _obj ?peer:_ = no_dbus
  end
#endif
