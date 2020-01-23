(* Copyright (C) 2020, Thomas Leonard
   See the README file for details, or visit http://0install.net. *)

(** Parsed feed imports. *)

type feed_type =
  | Feed_import             (* A <feed> import element inside a feed *)
  | User_registered         (* Added manually with "0install add-feed" : save to config *)
  | Site_packages           (* Found in the site-packages directory : save to config for older versions, but flag it *)
  | Distro_packages         (* Found in native_feeds : don't save *)

type t = {
  src : Feed_url.non_distro_feed;

  os : Arch.os option;           (* All impls requires this OS *)
  machine : Arch.machine option; (* All impls requires this CPU *)
  langs : string list option;    (* No impls for languages not listed *)
  ty : feed_type;
}

val make_user : [< Feed_url.non_distro_feed] -> t
