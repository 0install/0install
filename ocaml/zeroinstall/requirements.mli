(* Copyright (C) 2016, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** A structure representing constraints/requirements specified by the user *)

open Support.Common

type t = {
  interface_uri : Sigs.iface_uri;
  command : string option;
  source : bool;
  extra_restrictions : string StringMap.t;  (* iface -> range *)
  os : Arch.os option;
  cpu : Arch.machine option;
  message : string option;
  may_compile : bool;
}

val run : Sigs.iface_uri -> t
(** [run iface] is a requirement to run [iface] with no restrictions. *)

val of_json : Yojson.Basic.json -> t
val to_json : t -> Yojson.Basic.json
