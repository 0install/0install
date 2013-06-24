(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

let (+/) = Filename.concat;;

(** Useful 0install constants *)

let hours = 60 * 60         (* Seconds per hour *)

let days = 24 * hours       (* Seconds per day *)

module ZI_NS = struct
  let ns = "http://zero-install.sourceforge.net/2004/injector/interface";;
end;;

module ZI = Qdom.NsQuery (ZI_NS);;

exception Fallback_to_Python;;
